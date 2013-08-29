#define NULL 0
#define FALSE 0
#define TRUE (-1)

type FROGFILE as FROGFILE_

type TKLOCATION
	file		as FROGFILE ptr
	linenum		as integer
	column		as integer
	length		as integer
end type

declare sub oops( byref message as string )
declare sub oopsLocation _
	( _
		byval location as TKLOCATION ptr, _
		byref message as string _
	)
declare function strDuplicate( byval s as zstring ptr ) as zstring ptr
declare function strReplace _
	( _
		byref text as string, _
		byref a as string, _
		byref b as string _
	) as string
declare function strMakePrintable( byref a as string ) as string
declare function strMatches _
	( _
		byref origpattern as string, _
		byref s as string _
	) as integer
declare function strStartsWith( byref s as string, byref lookfor as string ) as integer
declare function strEndsWith( byref s as string, byref lookfor as string ) as integer

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

'' The hash table is an array of items,
'' which associate a string to some user data.
type THASHITEM
	s	as zstring ptr
	hash	as uinteger  '' hash value for quick comparison
	data	as any ptr   '' user data
end type

type THASH
	items		as THASHITEM ptr
	count		as integer  '' number of used items
	room		as integer  '' number of allocated items
	resizes		as integer  '' number of table reallocs/size increases
	lookups		as integer  '' lookup counter
	perfects	as integer  '' lookups successful after first probe
	collisions	as integer  '' sum of collisions during all lookups
end type

declare function hashHash( byval s as zstring ptr ) as uinteger
declare function hashLookup _
	( _
		byval h as THASH ptr, _
		byval s as zstring ptr, _
		byval hash as uinteger _
	) as THASHITEM ptr
declare sub hashAdd _
	( _
		byval h as THASH ptr, _
		byval item as THASHITEM ptr, _
		byval hash as uinteger, _
		byval s as zstring ptr, _
		byval dat as any ptr _
	)
declare sub hashAddOverwrite _
	( _
		byval h as THASH ptr, _
		byval s as zstring ptr, _
		byval dat as any ptr _
	)
declare sub hashInit( byval h as THASH ptr, byval exponent as integer )
declare sub hashEnd( byval h as THASH ptr )
declare sub hashStats( byval h as THASH ptr, byref prefix as string )

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

type LISTNODE
	next		as LISTNODE ptr
	prev		as LISTNODE ptr
end type

type TLIST
	head		as LISTNODE ptr
	tail		as LISTNODE ptr
	nodesize	as integer
end type

declare function listGetHead( byval l as TLIST ptr) as any ptr
declare function listGetTail( byval l as TLIST ptr) as any ptr
declare function listGetNext( byval p as any ptr ) as any ptr
declare function listGetPrev( byval p as any ptr ) as any ptr
declare function listAppend( byval l as TLIST ptr ) as any ptr
declare sub listDelete( byval l as TLIST ptr, byval p as any ptr )
declare function listCount( byval l as TLIST ptr ) as integer
declare sub listInit( byval l as TLIST ptr, byval unit as integer )
declare sub listEnd( byval l as TLIST ptr )

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

declare function pathStripExt( byref path as string ) as string
declare function pathExtOnly( byref path as string ) as string
declare function pathOnly( byref path as string ) as string
declare function pathAddDiv( byref path as string ) as string
declare function pathStripLastComponent( byref path as string ) as string
declare function pathFindCommonBase _
	( _
		byref aorig as string, _
		byref borig as string _
	) as string
declare function pathStripCommonBase _
	( _
		byref a as string, _
		byref b as string _
	) as string
declare function pathMakeAbsolute( byref path as string ) as string
declare function pathNormalize( byref path as string ) as string
declare function hFileExists( byref file as string ) as integer
declare sub hScanDirectoryForH _
	( _
		byref rootdir as string, _
		byval resultlist as TLIST ptr _
	)

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

'' When changing, update the table in ast.bas too!
enum
	TK_EOF
	TK_DIVIDER
	TK_PPINCLUDE
	TK_PPDEFINE
	TK_PPIF
	TK_PPELSEIF
	TK_PPELSE
	TK_PPENDIF
	TK_PPUNDEF
	TK_BEGIN
	TK_END
	TK_EOL
	TK_COMMENT

	'' Number literals
	TK_DECNUM
	TK_HEXNUM
	TK_OCTNUM
	TK_DECFLOAT

	'' String literals, sorted to match STRFLAG_*:
	TK_STRING       '' 000    "foo"
	TK_CHAR         '' 001    'c'
	TK_WSTRING      '' 010    L"foo"
	TK_WCHAR        '' 011    L'c'
	TK_ESTRING      '' 100    "\n"
	TK_ECHAR        '' 101    '\n'
	TK_EWSTRING     '' 110    L"\n"
	TK_EWCHAR       '' 111    L'\n'

	'' C/FB tokens
	TK_EXCL         '' !
	TK_EXCLEQ       '' !=
	TK_HASH         '' #
	TK_HASHHASH     '' ##
	TK_PERCENT      '' %
	TK_PERCENTEQ    '' %=
	TK_AMP          '' &
	TK_AMPEQ        '' &=
	TK_AMPAMP       '' &&
	TK_LPAREN       '' (
	TK_RPAREN       '' )
	TK_STAR         '' *
	TK_STAREQ       '' *=
	TK_PLUS         '' +
	TK_PLUSEQ       '' +=
	TK_PLUSPLUS     '' ++
	TK_COMMA        '' ,
	TK_MINUS        '' -
	TK_MINUSEQ      '' -=
	TK_MINUSMINUS   '' --
	TK_ARROW        '' ->
	TK_DOT          '' .
	TK_ELLIPSIS     '' ...
	TK_SLASH        '' /
	TK_SLASHEQ      '' /=
	TK_COLON        '' :
	TK_SEMI         '' ;
	TK_LT           '' <
	TK_LTLT         '' <<
	TK_LTLTEQ       '' <<=
	TK_LTEQ         '' <=
	TK_LTGT         '' <>
	TK_EQ           '' =
	TK_EQEQ         '' ==
	TK_GT           '' >
	TK_GTGT         '' >>
	TK_GTGTEQ       '' >>=
	TK_GTEQ         '' >=
	TK_QUEST        '' ?
	TK_AT           '' @
	TK_LBRACKET     '' [
	TK_BACKSLASH    '' \
	TK_RBRACKET     '' ]
	TK_CIRC         '' ^
	TK_CIRCEQ       '' ^=
	TK_UNDERSCORE   '' _
	TK_LBRACE       '' {
	TK_PIPE         '' |
	TK_PIPEEQ       '' |=
	TK_PIPEPIPE     '' ||
	TK_RBRACE       '' }
	TK_TILDE        '' ~

	'' >= TK_ID: keywords/identifiers
	TK_ID           '' Identifiers (a-z, A-Z, 0-9, _, $)

	'' C-only keywords
	KW__C_FIRST
	KW___ATTRIBUTE__ = KW__C_FIRST
	KW___CDECL
	KW___RESTRICT
	KW___RESTRICT__
	KW___STDCALL
	KW_AUTO
	KW_BREAK
	KW_CHAR
	KW_DEFAULT
	KW_ELIF
	KW_FLOAT
	KW_INLINE
	KW_REGISTER
	KW_RESTRICT
	KW_SIGNED
	KW_STRUCT
	KW_SWITCH
	KW_TYPEDEF
	KW_VOID
	KW_VOLATILE

	'' C/FB shared keywords
	KW__FB_FIRST
	KW_CASE = KW__FB_FIRST
	KW_CONST
	KW_CONTINUE
	KW_DEFINE
	KW_DEFINED
	KW_DO
	KW_DOUBLE
	KW_ELSE
	KW_ENDIF
	KW_ENUM
	KW_EXTERN
	KW_FOR
	KW_GOTO
	KW_IF
	KW_IFDEF
	KW_IFNDEF
	KW_INCLUDE
	KW_INT
	KW_LONG
	KW_PRAGMA
	KW_RETURN
	KW_SHORT
	KW_SIZEOF
	KW_STATIC
	KW_UNDEF
	KW_UNION
	KW_UNSIGNED
	KW_WHILE
	KW__C_LAST = KW_WHILE

	'' FB-only keywords
	KW__FROG_FIRST
	KW_ALIAS = KW__FROG_FIRST
	KW_AND
	KW_ANDALSO
	KW_ANY
	KW_AS
	KW_BYTE
	KW_BYVAL
	KW_CAST
	KW_CDECL
	KW_CPTR
	KW_DECLARE
	KW_DIM
	KW_ELSEIF
	KW_END
	KW_EXIT
	KW_EXPORT
	KW_FIELD
	KW_FUNCTION
	KW_IIF
	KW_INTEGER
	KW_LONGINT
	KW_LOOP
	KW_MACRO
	KW_MOD
	KW_NEXT
	KW_NOT
	KW_OPTION
	KW_OR
	KW_ORELSE
	KW_PASCAL
	KW_PRIVATE
	KW_PTR
	KW_SCOPE
	KW_SELECT
	KW_SHARED
	KW_SHL
	KW_SHR
	KW_SINGLE
	KW_STDCALL
	KW_SUB
	KW_THEN
	KW_TO
	KW_TYPE
	KW_TYPEOF
	KW_UBYTE
	KW_UINTEGER
	KW_ULONG
	KW_ULONGINT
	KW_USHORT
	KW_WEND
	KW_WSTR
	KW_WSTRING
	KW_XOR
	KW_ZSTRING
	KW__FB_LAST = KW_ZSTRING

	'' fbfrog-only keywords
	KW_DOWNLOAD
	KW_EXTRACT
	KW_EXPAND
	KW_FILE
	KW_VERSION
	KW__FROG_LAST = KW_VERSION

	TK__COUNT
end enum

declare function tkInfoText( byval tk as integer ) as zstring ptr

'' Debugging helper, for example: TRACE( x ), "decl begin"
#define TRACE( x ) print __FUNCTION__ + "(" + str( __LINE__ ) + "): " + tkDumpOne( x )

type ASTNODE as ASTNODE_

declare sub tkInit( )
declare sub tkEnd( )
declare function tkDumpBasic( byval id as integer, byval text as zstring ptr ) as string
declare function hDumpComment( byval comment as zstring ptr ) as string
declare function tkDumpOne( byval x as integer ) as string
declare sub tkDump( )
declare function tkGetCount( ) as integer
declare sub tkInsert _
	( _
		byval x as integer, _
		byval id as integer, _
		byval text as zstring ptr = NULL, _
		byval ast as ASTNODE ptr = NULL _
	)
declare sub tkRemove( byval first as integer, byval last as integer )
declare sub tkCopy( byval x as integer, byval first as integer, byval last as integer )
declare sub tkFold _
	( _
		byval first as integer, _
		byval last as integer, _
		byval id as integer, _
		byval text as zstring ptr = NULL, _
		byval ast as ASTNODE ptr = NULL _
	)
declare function tkGet( byval x as integer ) as integer
declare function tkGetText( byval x as integer ) as zstring ptr
declare function tkGetIdOrKw( byval x as integer ) as zstring ptr
declare function tkGetAst( byval x as integer ) as ASTNODE ptr
declare sub tkSetAst( byval x as integer, byval ast as ASTNODE ptr )
declare sub tkSetLocation( byval x as integer, byval location as TKLOCATION ptr )
declare function tkGetLocation( byval x as integer ) as TKLOCATION ptr
declare sub tkSetBehindSpace( byval x as integer )
declare function tkGetBehindSpace( byval x as integer ) as integer
declare sub tkSetComment( byval x as integer, byval comment as zstring ptr )
declare function tkGetComment( byval x as integer ) as zstring ptr
declare function tkCount _
	( _
		byval tk as integer, _
		byval first as integer, _
		byval last as integer _
	) as integer
declare function tkSkipComment _
	( _
		byval x as integer, _
		byval delta as integer = 1 _
	) as integer
declare function tkSkipCommentEol _
	( _
		byval x as integer, _
		byval delta as integer = 1 _
	) as integer
declare function tkToCText( byval id as integer, byval text as zstring ptr ) as string
declare function tkManyToCText _
	( _
		byval first as integer, _
		byval last as integer _
	) as string
declare function tkToAstText _
	( _
		byval first as integer, _
		byval last as integer _
	) as ASTNODE ptr
declare function tkCollectComments _
	( _
		byval first as integer, _
		byval last as integer _
	) as string
declare sub tkRemoveAllOf( byval id as integer, byval text as zstring ptr )
declare sub tkOops( byval x as integer, byref message as string )
declare sub tkOopsExpected( byval x as integer, byref message as string )
declare sub tkExpect( byval x as integer, byval tk as integer )

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

enum
	TYPE_NONE = 0
	TYPE_ANY
	TYPE_BYTE
	TYPE_UBYTE
	TYPE_ZSTRING
	TYPE_SHORT
	TYPE_USHORT
	TYPE_LONG
	TYPE_ULONG
	TYPE_INTEGER
	TYPE_UINTEGER
	TYPE_LONGINT
	TYPE_ULONGINT
	TYPE_SINGLE
	TYPE_DOUBLE
	TYPE_UDT
	TYPE_PROC
	TYPE__COUNT
end enum

const TYPEMASK_DT    = &b00000000000000000000000011111111  '' 1 byte, enough for TYPE_* enum
const TYPEMASK_PTR   = &b00000000000000000000111100000000  '' 0..15, enough for max. 8 PTRs on a type, like FB
const TYPEMASK_REF   = &b00000000000000000001000000000000  '' 0..1, reference or not?
const TYPEMASK_CONST = &b00000000001111111110000000000000  '' 1 bit per PTR + 1 for the toplevel

const TYPEPOS_PTR    = 8  '' bit where PTR mask starts
const TYPEPOS_REF    = TYPEPOS_PTR + 4
const TYPEPOS_CONST  = TYPEPOS_REF + 1

const TYPEMAX_PTR = 8

#define typeSetDt( dtype, dt ) ((dtype and (not TYPEMASK_DT)) or (dt and TYPEMASK_DT))
#define typeSetIsConst( dt ) ((dt) or (1 shl TYPEPOS_CONST))
#define typeIsConstAt( dt, at ) (((dt) and (1 shl (TYPEPOS_CONST + (at)))) <> 0)
#define typeGetDt( dt ) ((dt) and TYPEMASK_DT)
#define typeGetDtAndPtr( dt ) ((dt) and (TYPEMASK_DT or TYPEMASK_PTR))
#define typeGetPtrCount( dt ) (((dt) and TYPEMASK_PTR) shr TYPEPOS_PTR)
#define typeAddrOf( dt ) _
	(((dt) and TYPEMASK_DT) or _
	 (((dt) and TYPEMASK_PTR) + (1 shl TYPEPOS_PTR)) or _
	 (((dt) and TYPEMASK_CONST) shl 1))
#define typeMultAddrOf( dt, count ) _
	((dt and TYPEMASK_DT) or _
	 ((dt and TYPEMASK_PTR) + (count shl TYPEPOS_PTR)) or _
	 ((dt and TYPEMASK_CONST) shl count))
#define typeGetConst( dt ) ((dt) and TYPEMASK_CONST)

declare function typeToSigned( byval dtype as integer ) as integer
declare function typeToUnsigned( byval dtype as integer ) as integer
declare function typeIsFloat( byval dtype as integer ) as integer

enum
	ASTOP_IIF = 0  '' just for the operator precedence tables
	ASTOP_LOGOR
	ASTOP_LOGAND
	ASTOP_BITOR
	ASTOP_BITXOR
	ASTOP_BITAND
	ASTOP_EQ
	ASTOP_NE
	ASTOP_LT
	ASTOP_LE
	ASTOP_GT
	ASTOP_GE
	ASTOP_SHL
	ASTOP_SHR
	ASTOP_ADD
	ASTOP_SUB
	ASTOP_MUL
	ASTOP_DIV
	ASTOP_MOD
	ASTOP_LOGNOT
	ASTOP_BITNOT
	ASTOP_NEGATE
	ASTOP_UNARYPLUS
	ASTOP_DEFINED
end enum

enum
	ASTCLASS_NOP = 0
	ASTCLASS_GROUP
	ASTCLASS_VERSION
	ASTCLASS_DIVIDER

	ASTCLASS_PPINCLUDE
	ASTCLASS_PPDEFINE
	ASTCLASS_PPUNDEF
	ASTCLASS_PPIF
	ASTCLASS_PPELSEIF
	ASTCLASS_PPELSE
	ASTCLASS_PPENDIF

	ASTCLASS_STRUCT
	ASTCLASS_UNION
	ASTCLASS_ENUM
	ASTCLASS_TYPEDEF
	ASTCLASS_STRUCTFWD
	ASTCLASS_UNIONFWD
	ASTCLASS_ENUMFWD
	ASTCLASS_VAR
	ASTCLASS_FIELD
	ASTCLASS_ENUMCONST
	ASTCLASS_PROC
	ASTCLASS_PARAM
	ASTCLASS_ARRAY
	ASTCLASS_DIMENSION
	ASTCLASS_EXTERNBLOCKBEGIN
	ASTCLASS_EXTERNBLOCKEND

	ASTCLASS_MACROBODY
	ASTCLASS_MACROPARAM
	ASTCLASS_TK
	ASTCLASS_CONST
	ASTCLASS_ID
	ASTCLASS_TEXT

	ASTCLASS_UOP
	ASTCLASS_BOP
	ASTCLASS_IIF

	ASTCLASS__COUNT
end enum

enum
	ASTATTRIB_EXTERN	= 1 shl 0  '' VAR
	ASTATTRIB_PRIVATE	= 1 shl 1  '' VAR
	ASTATTRIB_OCT		= 1 shl 2  '' CONST
	ASTATTRIB_HEX		= 1 shl 3  '' CONST
	ASTATTRIB_MERGEWITHPREV	= 1 shl 4  '' TK, MACROPARAM: Macro body tokens that were preceded by the '##' PP merge operator
	ASTATTRIB_STRINGIFY	= 1 shl 5  '' MACROPARAM, to distinguish "param" from "#param"
	ASTATTRIB_CDECL		= 1 shl 6
	ASTATTRIB_STDCALL	= 1 shl 7
	ASTATTRIB_HIDECALLCONV	= 1 shl 8  '' Whether the calling convention is covered by an Extern block, then it doesn't need to be emitted
end enum

'' When changing, adjust astClone()
type ASTNODE_
	class		as integer  '' ASTCLASS_*
	attrib		as integer  '' ASTATTRIB_*

	'' Identifiers/string literals, or NULL
	text		as zstring ptr
	comment		as zstring ptr

	'' Data type (vars, fields, params, function results, expressions)
	dtype		as integer
	subtype		as ASTNODE ptr
	array		as ASTNODE ptr '' ARRAY holding DIMENSIONs, or NULL

	'' Source location where this declaration/statement was found
	location	as TKLOCATION

	'' PARAM: initializer
	'' PPDEFINE: MACROBODY
	'' VERSION: GROUP holding CONSTs (the individual version numbers)
	'' IIF: condition expression
	expr		as ASTNODE ptr

	'' Left/right operands for UOPs/BOPs
	l		as ASTNODE ptr
	r		as ASTNODE ptr

	union
		'' CONST: integer (longint) or float (double) value
		vali		as longint
		valf		as double

		tk		as integer  '' TK: TK_*
		paramindex	as integer  '' MACROPARAM
		paramcount	as integer  '' PPDEFINE: -1 = #define m, 0 = #define m(), 1 = #define m(a), ...
		op		as integer  '' UOP/BOP: ASTOP_*
	end union

	'' Linked list of child nodes, where l/r aren't enough: fields/parameters/...
	head		as ASTNODE ptr
	tail		as ASTNODE ptr
	next		as ASTNODE ptr
	prev		as ASTNODE ptr
end type

declare function astNew overload( byval class_ as integer ) as ASTNODE ptr
declare function astNew overload _
	( _
		byval class_ as integer, _
		byval text as zstring ptr _
	) as ASTNODE ptr
declare function astNewUOP _
	( _
		byval op as integer, _
		byval l as ASTNODE ptr _
	) as ASTNODE ptr
declare function astNewBOP _
	( _
		byval op as integer, _
		byval l as ASTNODE ptr, _
		byval r as ASTNODE ptr _
	) as ASTNODE ptr
declare function astNewIIF _
	( _
		byval cond as ASTNODE ptr, _
		byval l as ASTNODE ptr, _
		byval r as ASTNODE ptr _
	) as ASTNODE ptr
declare function astNewVERSION overload _
	( _
		byval child as ASTNODE ptr, _
		byval versionnum as integer _
	) as ASTNODE ptr
declare function astNewVERSION overload _
	( _
		byval child as ASTNODE ptr, _
		byval version1 as ASTNODE ptr, _
		byval version2 as ASTNODE ptr _
	) as ASTNODE ptr
declare function astNewDIMENSION _
	( _
		byval lb as ASTNODE ptr, _
		byval ub as ASTNODE ptr _
	) as ASTNODE ptr
declare function astNewCONST _
	( _
		byval i as longint, _
		byval f as double, _
		byval dtype as integer _
	) as ASTNODE ptr
#define astNewID( id ) astNew( ASTCLASS_ID, id )
declare function astNewTK _
	( _
		byval tk as integer, _
		byval text as zstring ptr _
	) as ASTNODE ptr
declare function astNewMACROPARAM _
	( _
		byval id as zstring ptr, _
		byval paramindex as integer _
	) as ASTNODE ptr
declare sub astDelete( byval n as ASTNODE ptr )
declare sub astPrepend( byval parent as ASTNODE ptr, byval n as ASTNODE ptr )
declare sub astAppend( byval parent as ASTNODE ptr, byval n as ASTNODE ptr )
declare sub astCloneAndAddAllChildrenOf( byval d as ASTNODE ptr, byval s as ASTNODE ptr )
declare function astVersionsMatch( byval a as ASTNODE ptr, byval b as ASTNODE ptr ) as integer
declare sub astAddVersionedChild( byval n as ASTNODE ptr, byval child as ASTNODE ptr )
declare function astSolveVersionsOut _
	( _
		byval nodes as ASTNODE ptr, _
		byval matchversion as ASTNODE ptr _
	) as ASTNODE ptr
declare function astIsChildOf _
	( _
		byval parent as ASTNODE ptr, _
		byval lookfor as ASTNODE ptr _
	) as integer
declare sub astAddChildBefore _
	( _
		byval parent as ASTNODE ptr, _
		byval n as ASTNODE ptr, _
		byval ref as ASTNODE ptr _
	)
declare function astReplaceChild _
	( _
		byval parent as ASTNODE ptr, _
		byval a as ASTNODE ptr, _
		byval b as ASTNODE ptr _
	) as ASTNODE ptr
declare sub astRemoveChild( byval parent as ASTNODE ptr, byval a as ASTNODE ptr )
declare sub astRemoveText( byval n as ASTNODE ptr )
declare sub astSetType _
	( _
		byval n as ASTNODE ptr, _
		byval dtype as integer, _
		byval subtype as ASTNODE ptr _
	)
declare sub astSetComment( byval n as ASTNODE ptr, byval comment as zstring ptr )
declare sub astAddComment( byval n as ASTNODE ptr, byval comment as zstring ptr )
declare function astCloneNode( byval n as ASTNODE ptr ) as ASTNODE ptr
declare function astClone( byval n as ASTNODE ptr ) as ASTNODE ptr
declare function astIsEqualDecl _
	( _
		byval a as ASTNODE ptr, _
		byval b as ASTNODE ptr, _
		byval ignore_fields as integer = FALSE, _
		byval ignore_hiddencallconv as integer = FALSE _
	) as integer
declare function astDumpOne( byval n as ASTNODE ptr ) as string
declare function astDumpInline( byval n as ASTNODE ptr ) as string
declare sub astDump _
	( _
		byval n as ASTNODE ptr, _
		byval nestlevel as integer = 0, _
		byref prefix as string = "" _
	)

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

enum
	LEXMODE_C = 0
	LEXMODE_FB
	LEXMODE_FBFROG
end enum

declare function lexLoadFile _
	( _
		byval x as integer, _
		byval file as FROGFILE ptr, _
		byval mode as integer, _
		byval keep_comments as integer _
	) as integer
declare function lexPeekLine _
	( _
		byval file as FROGFILE ptr, _
		byval targetlinenum as integer _
	) as string
declare function emitType _
	( _
		byval dtype as integer, _
		byval subtype as ASTNODE ptr, _
		byval debugdump as integer = FALSE _
	) as string
declare sub emitFile( byref filename as string, byval ast as ASTNODE ptr )
declare function importFile( byval file as FROGFILE ptr ) as ASTNODE ptr

declare sub ppComments( )
declare sub ppDividers( )
declare function hNumberLiteral( byval x as integer ) as ASTNODE ptr
declare sub hMacroParamList( byref x as integer, byval t as ASTNODE ptr )
declare sub ppDirectives1( )
declare sub hRecordMacroBody( byref x as integer, byval macro as ASTNODE ptr )
declare sub ppDirectives2( )
declare sub ppEvalInit( )
declare sub ppEvalEnd( )
declare sub ppMacroBegin( byval id as zstring ptr, byval paramcount as integer )
declare sub ppMacroToken( byval tk as integer, byval text as zstring ptr = NULL )
declare sub ppMacroParam( byval index as integer )
declare sub ppAddSym( byval id as zstring ptr, byval is_defined as integer )
declare sub ppExpandSym( byval id as zstring ptr )
declare sub ppEval( )
declare sub ppParseIfExprOnly( byval do_fold as integer )
declare sub ppRemoveEOLs( )
declare function cFile( ) as ASTNODE ptr

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

enum
	PRESETOPT_NOMERGE	= 1 shl 0
	PRESETOPT_COMMENTS	= 1 shl 1
	PRESETOPT_NOPP		= 1 shl 2
	PRESETOPT_NOPPFOLD	= 1 shl 3
	PRESETOPT_NOAUTOEXTERN	= 1 shl 4
end enum

type FROGPRESET
	versions		as ASTNODE ptr

	downloads		as ASTNODE ptr
	extracts		as ASTNODE ptr
	filecopies		as ASTNODE ptr
	files			as ASTNODE ptr

	defines			as ASTNODE ptr
	undefs			as ASTNODE ptr
	expands			as ASTNODE ptr
	macros			as ASTNODE ptr

	options			as integer
end type

declare sub frogLoadPreset( byval pre as FROGPRESET ptr, byref filename as string )
declare sub frogFreePreset( byval pre as FROGPRESET ptr )

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

type FROGFILE_
	pretty		as string '' Pretty name from command line or #include
	normed		as string '' Normalized path used in hash table
	missing		as integer '' File missing/not found?
	ast		as ASTNODE ptr  '' AST representing file content, when loaded
	refcount	as integer
	mergeparent	as FROGFILE ptr '' The file this one was merged into
	linecount	as integer
end type

type FROGSTUFF
	merge		as integer
	verbose		as integer
	preset		as string

	files		as TLIST '' FROGFILE
	filehash	as THASH
	commonparent	as string
end type

extern as FROGSTUFF frog
