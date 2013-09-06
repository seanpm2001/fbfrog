''
'' Parsing of FB code, i.e. re-importing of bindings generated by emitFile().
''

#include once "fbfrog.bi"

declare function imStructCompound( ) as ASTNODE ptr
declare function imProcDecl( byval is_procptr as integer ) as ASTNODE ptr

dim shared as integer x

private sub imOops( )
	print "error: unknown construct in AST dump, at this token:"
	print tkDumpOne( x )
	end 1
end sub

private function imSkip( byval y as integer ) as integer
	do
		y += 1

		select case( tkGet( y ) )
		case TK_COMMENT

		case else
			exit do
		end select
	loop

	function = y
end function

private sub hSkip( )
	x = imSkip( x )
end sub

private function hMatch( byval tk as integer ) as integer
	if( tkGet( x ) = tk ) then
		function = TRUE
		hSkip( )
	end if
end function

private sub hExpect( byval tk as integer )
	if( tkGet( x ) <> tk ) then
		imOops( )
	end if
end sub

private sub hExpectAndSkip( byval tk as integer )
	hExpect( tk )
	hSkip( )
end sub

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

'' FB operator precedence, starting at 1, higher value = higher precedence
dim shared as integer fbprecedence(ASTOP_IIF to ASTOP_STRINGIFY) = _
{ _
	 0, _ '' ASTOP_IIF
	 0, _ '' ASTOP_CLOGOR
	 0, _ '' ASTOP_CLOGAND
	 1, _ '' ASTOP_ORELSE
	 1, _ '' ASTOP_ANDALSO
	 3, _ '' ASTOP_OR
	 2, _ '' ASTOP_XOR
	 4, _ '' ASTOP_AND
	 0, _ '' ASTOP_CEQ
	 0, _ '' ASTOP_CNE
	 0, _ '' ASTOP_CLT
	 0, _ '' ASTOP_CLE
	 0, _ '' ASTOP_CGT
	 0, _ '' ASTOP_CGE
	 6, _ '' ASTOP_EQ
	 6, _ '' ASTOP_NE
	 6, _ '' ASTOP_LT
	 6, _ '' ASTOP_LE
	 6, _ '' ASTOP_GT
	 6, _ '' ASTOP_GE
	 8, _ '' ASTOP_SHL
	 8, _ '' ASTOP_SHR
	 7, _ '' ASTOP_ADD
	 7, _ '' ASTOP_SUB
	10, _ '' ASTOP_MUL
	10, _ '' ASTOP_DIV
	 9, _ '' ASTOP_MOD
	 0, _ '' ASTOP_INDEX
	 0, _ '' ASTOP_MEMBER
	 0, _ '' ASTOP_MEMBERDEREF
	 0, _ '' ASTOP_CLOGNOT
	 5, _ '' ASTOP_NOT
	11, _ '' ASTOP_NEGATE
	11, _ '' ASTOP_UNARYPLUS
	 0, _ '' ASTOP_CDEFINED
	 0, _ '' ASTOP_DEFINED
	 0, _ '' ASTOP_ADDROF
	 0, _ '' ASTOP_DEREF
	 0  _ '' ASTOP_STRINGIFY
}

'' FB expression parser based on precedence climbing
private function imExpression _
	( _
		byval is_pp as integer, _
		byval level as integer = 0 _
	) as ASTNODE ptr

	'' Unary prefix operators
	var op = -1
	select case( tkGet( x ) )
	case KW_NOT   : op = ASTOP_NOT       '' NOT
	case TK_MINUS : op = ASTOP_NEGATE    '' -
	case TK_PLUS  : op = ASTOP_UNARYPLUS '' +
	end select

	dim as ASTNODE ptr a
	if( op >= 0 ) then
		hSkip( )
		a = astNewUOP( op, imExpression( is_pp, fbprecedence(op) ) )
	else
		'' Atoms
		select case( tkGet( x ) )
		'' '(' Expression ')'
		case TK_LPAREN
			hSkip( )

			'' Expression
			a = imExpression( is_pp )

			'' ')'
			hExpectAndSkip( TK_RPAREN )

		case TK_OCTNUM, TK_DECNUM, TK_HEXNUM, TK_DECFLOAT
			a = hNumberLiteral( x )
			hSkip( )

		'' DEFINED '(' Identifier ')'
		case KW_DEFINED
			if( is_pp = FALSE ) then
				imOops( )
			end if
			hSkip( )

			'' '('
			hExpectAndSkip( TK_LPAREN )

			'' Identifier
			hExpect( TK_ID )
			a = astNewID( tkGetText( x ) )
			hSkip( )

			'' ')'
			hExpectAndSkip( TK_RPAREN )

			a = astNewUOP( ASTOP_DEFINED, a )

		'' IIF '(' Expression ',' Expression ',' Expression ')'
		case KW_IIF
			hSkip( )

			'' '('
			hExpectAndSkip( TK_LPAREN )

			a = imExpression( is_pp )

			'' ','
			hExpectAndSkip( TK_COMMA )

			var b = imExpression( is_pp )

			'' ','
			hExpectAndSkip( TK_COMMA )

			var c = imExpression( is_pp )

			'' ')'
			hExpectAndSkip( TK_RPAREN )

			a = astNewIIF( a, b, c )

		case else
			imOops( )
		end select
	end if

	'' Infix operators
	do
		select case as const( tkGet( x ) )
		case KW_ORELSE   : op = ASTOP_ORELSE  '' ORELSE
		case KW_ANDALSO  : op = ASTOP_ANDALSO '' ANDALSO
		case KW_OR       : op = ASTOP_OR      '' OR
		case KW_XOR      : op = ASTOP_XOR     '' XOR
		case KW_AND      : op = ASTOP_AND     '' AND
		case TK_EQ       : op = ASTOP_EQ      '' =
		case TK_LTGT     : op = ASTOP_NE      '' <>
		case TK_LT       : op = ASTOP_LT      '' <
		case TK_LTEQ     : op = ASTOP_LE      '' <=
		case TK_GT       : op = ASTOP_GT      '' >
		case TK_GTEQ     : op = ASTOP_GE      '' >=
		case KW_SHL      : op = ASTOP_SHL     '' SHL
		case KW_SHR      : op = ASTOP_SHR     '' SHR
		case TK_PLUS     : op = ASTOP_ADD     '' +
		case TK_MINUS    : op = ASTOP_SUB     '' -
		case TK_STAR     : op = ASTOP_MUL     '' *
		case TK_SLASH    : op = ASTOP_DIV     '' /
		case KW_MOD      : op = ASTOP_MOD     '' MOD
		case else        : exit do
		end select

		'' Higher/same level means process now (takes precedence),
		'' lower level means we're done and the parent call will
		'' continue. The first call will start with level 0.
		var oplevel = fbprecedence(op)
		if( oplevel < level ) then
			exit do
		end if

		'' operator
		hSkip( )

		'' rhs
		var b = imExpression( is_pp, oplevel )

		a = astNewBOP( op, a, b )
	loop

	function = a
end function

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

private function imPPDirective( ) as ASTNODE ptr
	'' '#'
	hSkip( )

	var tk = tkGet( x )
	select case( tk )
	case KW_DEFINE
		hSkip( )

		'' Identifier
		hExpect( TK_ID )
		function = astNew( ASTCLASS_PPDEFINE, tkGetText( x ) )
		hSkip( )

	case KW_INCLUDE
		hSkip( )

		'' "filename"
		hExpect( TK_STRING )
		function = astNew( ASTCLASS_PPINCLUDE, tkGetText( x ) )
		hSkip( )

	case KW_UNDEF
		hSkip( )

		'' Identifier?
		hExpect( TK_ID )
		function = astNew( ASTCLASS_PPUNDEF, tkGetText( x ) )
		hSkip( )

	case else
		imOops( )
	end select

	hExpectAndSkip( TK_EOL )
end function

private sub imConstMod( byref dtype as integer )
	'' [CONST]
	if( tkGet( x ) = KW_CONST ) then
		hSkip( )
		dtype = typeSetIsConst( dtype )
	end if
end sub

private sub imDataType( byref dtype as integer, byref subtype as ASTNODE ptr )
	dtype = TYPE_NONE
	subtype = NULL

	'' [CONST]
	var is_const = hMatch( KW_CONST )

	'' base data type
	select case( tkGet( x ) )
	case KW_ANY      : dtype = TYPE_ANY      : hSkip( )
	case KW_BYTE     : dtype = TYPE_BYTE     : hSkip( )
	case KW_UBYTE    : dtype = TYPE_UBYTE    : hSkip( )
	case KW_SHORT    : dtype = TYPE_SHORT    : hSkip( )
	case KW_USHORT   : dtype = TYPE_USHORT   : hSkip( )
	case KW_LONG     : dtype = TYPE_LONG     : hSkip( )
	case KW_ULONG    : dtype = TYPE_ULONG    : hSkip( )
	case KW_INTEGER  : dtype = TYPE_INTEGER  : hSkip( )
	case KW_UINTEGER : dtype = TYPE_UINTEGER : hSkip( )
	case KW_LONGINT  : dtype = TYPE_LONGINT  : hSkip( )
	case KW_ULONGINT : dtype = TYPE_ULONGINT : hSkip( )
	case KW_SINGLE   : dtype = TYPE_SINGLE   : hSkip( )
	case KW_DOUBLE   : dtype = TYPE_DOUBLE   : hSkip( )
	case KW_ZSTRING  : dtype = TYPE_ZSTRING  : hSkip( )
	case TK_ID       : dtype = TYPE_UDT      : hSkip( )

	'' TYPEOF '(' DataType ')'
	case KW_TYPEOF
		hSkip( )

		'' '('
		hExpectAndSkip( TK_LPAREN )

		'' DataType
		imDataType( dtype, subtype )

		'' ')'
		hExpectAndSkip( TK_RPAREN )

	'' [DECLARE] SUB|FUNCTION '(' Parameters ')' [AS FunctionResultDataType]
	'' (function pointer types)
	'' Special syntax: Allowing DECLARE in data type to indicate a procedure
	'' type instead of a procedure pointer type.
	case KW_DECLARE, KW_SUB, KW_FUNCTION
		var is_declare = FALSE
		if( tkGet( x ) = KW_DECLARE ) then
			is_declare = TRUE
			hSkip( )
		end if

		dtype = iif( is_declare, TYPE_PROC, typeAddrOf( TYPE_PROC ) )
		subtype = imProcDecl( TRUE )

	case else
		imOops( )
	end select

	if( is_const ) then
		dtype = typeSetIsConst( dtype )
	end if

	'' ([CONST] PTR)*
	do
		'' [CONST]
		is_const = hMatch( KW_CONST )

		'' PTR?
		if( hMatch( KW_PTR ) = FALSE ) then
			if( is_const ) then
				imOops( )
			end if
			exit do
		end if
		dtype = typeAddrOf( dtype )

		if( is_const ) then
			dtype = typeSetIsConst( dtype )
		end if
	loop
end sub

enum
	DECL_DIMSHARED = 0
	DECL_EXTERN
	DECL_PARAM
	DECL_FIELD
end enum

private function imVarDecl( byval decl as integer ) as ASTNODE ptr
	dim as string id

	'' [Identifier]
	if( decl = DECL_PARAM ) then
		if( tkGet( x ) = TK_ID ) then
			id = *tkGetText( x )
			hSkip( )
		end if
	else
		hExpect( TK_ID )
		id = *tkGetText( x )
		hSkip( )
	end if

	dim as integer astclass
	select case( decl )
	case DECL_DIMSHARED, DECL_EXTERN
		astclass = ASTCLASS_VAR
	case DECL_PARAM
		astclass = ASTCLASS_PARAM
	case DECL_FIELD
		astclass = ASTCLASS_FIELD
	case else
		assert( FALSE )
	end select
	var t = astNew( astclass, id )

	select case( decl )
	case DECL_EXTERN
		t->attrib or= ASTATTRIB_EXTERN
	case DECL_DIMSHARED
		t->attrib or= ASTATTRIB_PRIVATE
	end select

	'' AS
	hExpectAndSkip( KW_AS )

	'' DataType
	imDataType( t->dtype, t->subtype )

	function = t
end function

private function imTypeMemberOrPP( ) as ASTNODE ptr
	select case( tkGet( x ) )
	case TK_HASH  '' #
		function = imPPDirective( )
	case KW_TYPE, KW_UNION
		'' Disambiguate: type AS DataType vs. TYPE : ... : END TYPE
		if( tkGet( imSkip( x ) ) <> KW_AS ) then
			function = imStructCompound( )
		else
			function = imVarDecl( DECL_FIELD )
		end if
	case else
		function = imVarDecl( DECL_FIELD )
	end select
end function

private function imStructCompound( ) as ASTNODE ptr
	'' TYPE|UNION
	var topkw = tkGet( x )
	hSkip( )

	'' [Identifier]
	dim as string id
	if( tkGet( x ) = TK_ID ) then
		id = *tkGetText( x )
		hSkip( )
	end if

	hExpectAndSkip( TK_EOL )

	var struct = astNew( iif( topkw = KW_UNION, ASTCLASS_UNION, ASTCLASS_STRUCT ) )

	'' body
	do
		'' END TYPE|UNION?
		if( tkGet( x ) = KW_END ) then
			if( tkGet( imSkip( x ) ) = topkw ) then
				exit do
			end if
		end if

		astAppend( struct, imTypeMemberOrPP( ) )
	loop

	'' END TYPE|UNION
	hExpectAndSkip( KW_END )
	hExpectAndSkip( topkw )
	hExpectAndSkip( TK_EOL )

	function = struct
end function

'' Identifier ['=' Expression]
private function imEnumConst( ) as ASTNODE ptr
	hExpect( TK_ID )
	var enumconst = astNew( ASTCLASS_ENUMCONST, tkGetText( x ) )
	hSkip( )

	'' '='?
	if( tkGet( x ) = TK_EQ ) then
		hSkip( )

		'' Expression
		enumconst->expr = imExpression( FALSE )
	end if

	hExpectAndSkip( TK_EOL )

	function = enumconst
end function

private function imEnumCompound( ) as ASTNODE ptr
	'' ENUM
	hSkip( )

	'' [Identifier]
	dim as string id
	if( tkGet( x ) = TK_ID ) then
		id = *tkGetText( x )
		hSkip( )
	end if

	hExpectAndSkip( TK_EOL )

	var t = astNew( ASTCLASS_ENUM )

	'' body
	do
		'' END ENUM?
		if( tkGet( x ) = KW_END ) then
			if( tkGet( imSkip( x ) ) = KW_ENUM ) then
				exit do
			end if
		end if

		astAppend( t, imEnumConst( ) )
	loop

	'' END ENUM
	hExpectAndSkip( KW_END )
	hExpectAndSkip( KW_ENUM )
	hExpectAndSkip( TK_EOL )

	function = t
end function

'' '...' | BYVAL [Identifier] AS DataType
private function imParamDecl( ) as ASTNODE ptr
	'' '...'?
	if( tkGet( x ) = TK_ELLIPSIS ) then
		hSkip( )
		function = astNew( ASTCLASS_PARAM )
	else
		'' BYVAL
		hExpectAndSkip( KW_BYVAL )

		function = imVarDecl( DECL_PARAM )
	end if
end function

'' '(' Parameter (',' Parameter)* ')'
private sub imParamList( byval proc as ASTNODE ptr )
	TRACE( x )
	'' '('
	hExpectAndSkip( TK_LPAREN )

	'' not just '()'?
	if( tkGet( x ) <> TK_RPAREN ) then
		do
			TRACE( x )
			'' Parameter
			astAppend( proc, imParamDecl( ) )

			'' ','?
		loop while( hMatch( TK_COMMA ) )
	end if

	'' ')'
	TRACE( x )
	hExpectAndSkip( TK_RPAREN )
end sub

'' SUB|FUNCTION [Identifier] '(' Parameters ')' [AS FunctionResultDataType]
private function imProcDecl( byval is_procptr as integer ) as ASTNODE ptr
	TRACE( x )

	'' SUB|FUNCTION
	var prockw = tkGet( x )
	select case( prockw )
	case KW_SUB, KW_FUNCTION

	case else
		imOops( )
	end select
	hSkip( )

	TRACE( x )

	dim id as string
	if( is_procptr = FALSE ) then
		'' Identifier
		hExpect( TK_ID )
		id = *tkGetText( x )
		hSkip( )
	end if

	var proc = astNew( ASTCLASS_PROC, id )

	TRACE( x )

	'' '(' Parameters ')'
	imParamList( proc )

	TRACE( x )

	'' [AS FunctionResultDataType]
	if( prockw = KW_FUNCTION ) then
		'' AS
		hExpectAndSkip( KW_AS )

		'' DataType
		imDataType( proc->dtype, proc->subtype )
	end if

	TRACE( x )

	function = proc
end function

private function imCompoundOrStatement( ) as ASTNODE ptr
	TRACE( x )

	select case( tkGet( x ) )
	case TK_HASH  '' #
		function = imPPDirective( )

	case KW_TYPE, KW_UNION
		function = imStructCompound( )

	case KW_ENUM
		function = imEnumCompound( )

	case KW_DIM
		hSkip( )

		'' SHARED
		dim as integer decl
		select case( tkGet( x ) )
		case KW_SHARED
			decl = DECL_DIMSHARED
		case else
			imOops( )
		end select
		hSkip( )

		function = imVarDecl( decl )

		hExpectAndSkip( TK_EOL )

	case KW_EXTERN
		hSkip( )
		function = imVarDecl( DECL_EXTERN )

		hExpectAndSkip( TK_EOL )

	case KW_DECLARE
		'' DECLARE
		hSkip( )

		function = imProcDecl( FALSE )

		hExpectAndSkip( TK_EOL )

	case TK_EOL
		hSkip( )

	case TK_EOF

	case else
		imOops( )
	end select
end function

private function imToplevel( ) as ASTNODE ptr
	var group = astNewGROUP( )

	x = imSkip( -1 )
	while( tkGet( x ) <> TK_EOF )
		astAppend( group, imCompoundOrStatement( ) )
	wend

	function = group
end function

function importFile( byval file as FROGFILE ptr ) as ASTNODE ptr
	tkInit( )
	lexLoadFile( 0, file, LEXMODE_FB, FALSE )
	function = imToplevel( )
	tkEnd( )
end function
