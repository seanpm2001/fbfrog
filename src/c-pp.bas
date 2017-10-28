''
'' C pre-processor
''
'' cppMain() goes through the token buffer much like a C preprocessor would do,
'' parsing CPP directives keeping track of #defines and #undefs, doing macro
'' expansion, evaluating #if blocks, and expanding #includes.
''
'' All tokens that shouldn't be preserved for the C parser later are marked via
'' tkSetRemove() (for tkApplyRemoves() later). This affects most directives and
'' all tokens skipped in #if 0 blocks. As a special case, #defines and
'' unexpanded #includes are not deleted, but preserved for the C parser, because
'' we want to parse them there too.
''
'' Since directives are not deleted from the token buffer immediately, we can
'' leave #define bodies in place, and copy the tokens from there whenever they
'' are needed for a macro expansion. Otherwise it would be necessary to load the
'' tokens into some AST.
''
'' In various places (especially during macro expansion), we're temporarily
'' inserting helper tokens such as TK_ARGBEGIN/TK_ARGEND to enclose a range of
'' tokens. Then, instead of having to keep track of token indices which change
'' on every insertion/deletion, we just have to watch out for those specific
'' helper tokens to detect begin/end of the range.
''
'' We insert TK_ENDINCLUDE behind tokens inserted due to #include expansion.
'' This allows detecting #include EOF for the #if/#include stack.
''
'' #includes statements are preserved as-is and the #included content is
'' inserted behind them (if the file could be found). The point is to let the
'' CPP and C parser see as much code as possible, making the translation as
'' accurate as possible, but also to preserve the #include statements. Later it
'' will all be taken apart and distributed into .bi files as specified by the
'' -emit options, and the #include statements will be removed then, if the
'' #include content will be kept instead.
''

#include once "c-pp.bi"
#include once "c-common.bi"
#include once "c-lex.bi"
#include once "fbfrog.bi"
#include once "util-path.bi"

#include once "crt.bi"
#include once "file.bi"

using tktokens

destructor DefineInfo()
	astDelete(macro)
end destructor

function DefineInfo.clone() as DefineInfo ptr
	var b = new DefineInfo
	b->xbody   = xbody
	b->xeol    = xeol
	b->macro   = astClone(macro)
	function = b
end function

const DEFINEBODY_FLAGMASK = not (TKFLAG_REMOVE or TKFLAG_DIRECTIVE)

'' Copy a #define body into some other place
sub DefineInfo.copyBody(byval x as integer)
	assert(x > xeol)
	tkCopy(x, xbody, xeol - 1, DEFINEBODY_FLAGMASK)
end sub

'' Compare two #defines and determine whether they are equal
function DefineInfo.equals(byval b as DefineInfo ptr) as integer
	'' Check name, parameters and body
	return astIsEqual(macro, b->macro) andalso tkSpell(xbody, xeol) = tkSpell(b->xbody, b->xeol)
end function

destructor SavedMacro()
	deallocate(id)
	delete definfo
end destructor

enum
	'' If stack states:
	STATE_FILE = 0  '' file context (fresh toplevel/#include file, no #if yet)
	STATE_IF        '' #if context, fresh
	STATE_TRUE      '' #if context, saw #if/#elseif TRUE (and thus, further #elseif TRUE's must be skipped)
	STATE_ELSE      '' #if context, saw #else (and no further #elseif/#else can be allowed)
end enum

enum
	'' unknown = 0
	GUARDSTATE_CHECKING = 1
	GUARDSTATE_KNOWN
end enum

constructor CppContext(byref api as ApiInfo)
	this.api = @api
	x = 0

	'' Toplevel file context
	with stack(0)
		.state = STATE_FILE
		.knownfile = -1
		.incdir = NULL
	end with
	level = 0
	skiplevel = MAXSTACK  '' No skipping yet
	filelevel = 0

	savedmacros = NULL
	savedmacrocount = 0
	incdirs = astNewGROUP()

	files = NULL
	filecount = 0
end constructor

destructor CppContext()
	for i as integer = 0 to macros.room - 1
		delete cptr(DefineInfo ptr, macros.items[i].data)
	next
	for i as integer = 0 to savedmacrocount - 1
		savedmacros[i].destructor()
	next
	deallocate(savedmacros)
	astDelete(incdirs)
	for i as integer = 0 to filecount - 1
		with files[i]
			deallocate(.incfile)
			deallocate(.guard)
		end with
	next
	deallocate(files)
end destructor

function CppContext.isSkipping() as integer
	return (skiplevel <> MAXSTACK)
end function

sub CppContext.addPredefine(byval id as zstring ptr, byval body as zstring ptr)
	var s = "#define " + *id
	if body then
		s += " " + *body
	end if
	s += !"\n"
	var y = tkGetCount()
	lexLoadC(y, s, sourceinfoForZstring("pre-#define"))
	tkSetRemove(y, tkGetCount() - 1)
end sub

sub CppContext.addTargetPredefines(byval target as TargetInfo)
	addPredefine(osinfo(target.os).fbdefine, "1")
	if archinfo(target.arch).is_64bit then addPredefine("__FB_64BIT__", "1")
	if archinfo(target.arch).is_arm   then addPredefine("__FB_ARM__"  , "1")
end sub

sub CppContext.addIncDir(byval incdir as zstring ptr)
	astAppend(incdirs, astNewTEXT(incdir))
end sub

sub CppContext.appendIncludeDirective(byval filename as zstring ptr, byval tkflags as integer)
	var code = "#include """ + *filename + """" + !"\n"
	var y = tkGetCount()
	lexLoadC(y, code, sourceinfoForZstring(code))
	tkAddFlags(y, tkGetCount() - 1, TKFLAG_REMOVE or tkflags)
end sub

function CppContext.lookupMacro(byval id as zstring ptr) as DefineInfo ptr
	function = macros.lookupDataOrNull(id)
end function

function CppContext.isKnownSymbol(byval id as zstring ptr) as integer
	function = (macros.lookup(id, hashHash(id))->s <> NULL)
end function

function CppContext.isMacroCurrentlyDefined(byval id as zstring ptr) as integer
	function = (lookupMacro(id) <> NULL)
end function

'' Add/overwrite a known macro definition (or register it as known undefined)
sub CppContext.addMacro(byval id as zstring ptr, byval definfo as DefineInfo ptr)
	var hash = hashHash(id)
	var item = macros.lookup(id, hash)
	if item->s then
		delete cptr(DefineInfo ptr, item->data)
		item->data = definfo
	else
		macros.add(item, hash, id, definfo)
	end if
end sub

sub CppContext.addKnownUndefined(byval id as zstring ptr)
	addMacro(id, NULL)
end sub

'' Append a new entry to the array of saved macros
sub CppContext.appendSavedMacro(byval id as zstring ptr, byval definfo as DefineInfo ptr)
	savedmacrocount += 1
	savedmacros = reallocate(savedmacros, savedmacrocount * sizeof(SavedMacro))
	with savedmacros[savedmacrocount-1]
		.id = strDuplicate(id)
		.definfo = definfo
	end with
end sub

sub CppContext.removeSavedMacro(byval i as integer)
	assert((i >= 0) and (i < savedmacrocount))

	var p = savedmacros + i
	p->destructor()
	savedmacrocount -= 1

	'' Remove array element from the middle of the array: move all elements
	'' behind it to the front, by 1 slot, to close the gap.
	var tail = savedmacrocount - i
	if tail > 0 then
		memmove(p, p + 1, tail * sizeof(SavedMacro))
	end if
end sub

function CppContext.lookupSavedMacro(byval id as zstring ptr) as integer
	for i as integer = savedmacrocount - 1 to 0 step -1
		if *savedmacros[i].id = *id then
			return i
		end if
	next
	function = -1
end function

sub CppContext.saveMacro(byval id as zstring ptr)
	'' Check the macro's current state.
	'' If it's defined, we need to duplicate the DefineInfo object;
	'' otherwise, if it's undefined, we use NULL.
	var definfo = lookupMacro(id)
	if definfo then
		definfo = definfo->clone()
	end if
	appendSavedMacro(id, definfo)
end sub

sub CppContext.restoreMacro(byval id as zstring ptr)
	'' Search for the last saved macro for this id
	var i = lookupSavedMacro(id)
	if i < 0 then
		exit sub
	end if

	'' Restore the macro state
	var m = @savedmacros[i]
	if m->definfo then
		'' It was defined when saved, (re)-#define the macro
		addMacro(id, m->definfo)
		m->definfo = NULL
	else
		'' It was undefined when saved, #undef the macro
		addKnownUndefined(id)
	end if

	'' Remove the entry from the saved macros stack
	removeSavedMacro(i)
end sub

function CppContext.lookupOrAppendKnownFile(byval incfile as zstring ptr, byref prettyfile as string) as integer
	var hash = hashHash(incfile)
	var item = filetb.lookup(incfile, hash)
	if item->s then
		return cint(item->data)
	end if

	incfile = strDuplicate(incfile)

	var i = filecount
	filecount += 1
	files = reallocate(files, filecount * sizeof(*files))

	clear(files[i], 0, sizeof(*files))
	with files[i]
		.incfile = incfile
	end with

	filetb.add(item, hash, incfile, cptr(any ptr, i))
	function = i
end function

sub CppContext.parseEol()
	if tkGet(x) <> TK_EOL then
		tkOopsExpected(x, "end-of-line behind CPP directive")
	end if
	x += 1
end sub

function CppContext.parseStringLiteral(byval eval_escapes as integer) as string
	dim errmsg as string
	var s = hStringLiteral(x, eval_escapes, errmsg)
	if s = NULL then
		tkOops(x, errmsg)
	end if
	function = *s->text
	astDelete(s)
	x += 1
end function

sub CppContext.checkForUnknownSymbol(byval id as zstring ptr)
	if isKnownSymbol(id) = FALSE then
		'' Unknown symbol; we're going to assume that it's undefined

		'' Show a warning if it seems to be useful; i.e. if it's not a reserved symbol,
		'' but one intended to be defined by the user.
		if frog.verbose then
			if strIsReservedIdInC(id) = FALSE then
				print "treating as undefined: " + *id
			end if
		end if

		'' Register as known undefined
		'' This also prevents the above warning from being shown
		'' multiple times for a single symbol.
		'' TODO: but only with-in a single CPP run, not globally; this should be fixed
		addKnownUndefined(id)
	end if
end sub

''
'' CPP expression parser and evaluator
''
'' - The expression parsing is based on a "precedence climbing" algorithm
''
'' - Operations are evaluated as intmax_t or uintmax_t, i.e. 64bit signed or
''   unsigned, as in gcc/clang
''
'' - For most unary/binary operations we need to check the operand in order to
''   determine the result dtype (signed -> unsigned promotion rules can affect
''   the result). Others (e.g. the logical and relational ones) always return
''   a signed int regardless of the operands' dtypes.
''
'' - &&, || and ?: operands must only be evaluated when actually reached, such
''   that we can ignore division by zero if it occurs on an irrelevant code
''   path. (same goes for our "assuming undefined" warnings though - they should
''   only be shown if it affects the outcome of the expression)
''
'' - The ?: ternary conditional operator is a special case: one of its operands
''   mustn't be evaluated, but we still need to determine its dtype to determine
''   the result dtype of the ?: operation. Because of this we have to
''   differentiate between "evaluation" and "dtype determination" modes.
''
'' - Taking care to produce C's 1|0 boolean values, instead of FB's -1|0
''
'' a =  -a
'' a =  a + b
'' a =  a ? b : c
''
'' a = operand for UOPs, lhs operand for BOPs, result value to return
'' b = rhs operand for BOPs
'' c = 3rd operand for ?: conditional
''
sub CppContext.parseExpr(byref a as CPPVALUE, byval dtype_only as integer, byval level as integer = 0)
	'' Unary prefix operators
	select case tkGet(x)
	case TK_EXCL  '' !
		x += 1

		'' operand
		parseExpr(a, dtype_only, cprecedence(ASTKIND_CLOGNOT))

		a.vali = -(a.vali = 0)
		a.dtype = TYPE_LONGINT  '' ! operator always produces a signed int

	case TK_TILDE  '' ~
		x += 1

		'' operand
		parseExpr(a, dtype_only, cprecedence(ASTKIND_NOT))

		a.vali = not a.vali

	case TK_MINUS  '' -
		x += 1

		'' operand
		parseExpr(a, dtype_only, cprecedence(ASTKIND_NEGATE))

		a.vali = -a.vali

	case TK_PLUS  '' +
		x += 1

		'' operand
		parseExpr(a, dtype_only, cprecedence(ASTKIND_UNARYPLUS))

	'' Atoms
	case TK_LPAREN  '' '(' Expression ')'
		'' '('
		x += 1

		'' Expression
		parseExpr(a, dtype_only)

		'' ')'
		tkExpect(x, TK_RPAREN, "for '(...)' parenthesized expression")
		x += 1

	case TK_NUMBER  '' Number literal
		dim errmsg as string
		var n = hNumberLiteral(x, TRUE, errmsg, api->clong32)
		if n = NULL then
			tkOops(x, errmsg)
		end if
		if n->kind = ASTKIND_CONSTF then
			tkOops(x, "float literal in CPP expression")
		end if

		assert((n->dtype = TYPE_LONGINT) or (n->dtype = TYPE_ULONGINT))
		a.vali = astEvalConstiAsInt64(n)
		a.dtype = n->dtype

		astDelete(n)

		x += 1

	'' Unexpanded identifier: treated as a literal 0
	case TK_ID
		if dtype_only = FALSE then
			checkForUnknownSymbol(tkSpellId(x))
		end if
		a.vali = 0
		a.dtype = TYPE_LONGINT

		x += 1

	'' DEFINED ['('] Identifier [')']
	case KW_DEFINED
		x += 1

		'' '('
		var have_parens = FALSE
		if tkGet(x) = TK_LPAREN then
			have_parens = TRUE
			x += 1
		end if

		'' Identifier
		if tkGet(x) < TK_ID then
			tkExpect(x, TK_ID, "as operand of DEFINED")
		end if
		if dtype_only = FALSE then
			var id = tkSpellId(x)
			checkForUnknownSymbol(id)
			'' defined()  ->  1|0
			a.vali = -isMacroCurrentlyDefined(id)
		end if
		a.dtype = TYPE_LONGINT
		x += 1

		if have_parens then
			'' ')'
			tkExpect(x, TK_RPAREN, "for DEFINED(...)")
			x += 1
		end if

	case else
		tkOopsExpected(x, "expression")
	end select

	'' Infix operators
	do
		dim op as integer
		select case as const tkGet(x)
		case TK_QUEST    : op = ASTKIND_IIF     '' ? (a ? b : c)
		case TK_PIPEPIPE : op = ASTKIND_CLOGOR  '' ||
		case TK_AMPAMP   : op = ASTKIND_CLOGAND '' &&
		case TK_PIPE     : op = ASTKIND_OR      '' |
		case TK_CIRC     : op = ASTKIND_XOR     '' ^
		case TK_AMP      : op = ASTKIND_AND     '' &
		case TK_EQEQ     : op = ASTKIND_CEQ     '' ==
		case TK_EXCLEQ   : op = ASTKIND_CNE     '' !=
		case TK_LT       : op = ASTKIND_CLT     '' <
		case TK_LTEQ     : op = ASTKIND_CLE     '' <=
		case TK_GT       : op = ASTKIND_CGT     '' >
		case TK_GTEQ     : op = ASTKIND_CGE     '' >=
		case TK_LTLT     : op = ASTKIND_SHL     '' <<
		case TK_GTGT     : op = ASTKIND_SHR     '' >>
		case TK_PLUS     : op = ASTKIND_ADD     '' +
		case TK_MINUS    : op = ASTKIND_SUB     '' -
		case TK_STAR     : op = ASTKIND_MUL     '' *
		case TK_SLASH    : op = ASTKIND_DIV     '' /
		case TK_PERCENT  : op = ASTKIND_MOD     '' %
		case else        : exit do
		end select

		'' Higher/same level means process now (takes precedence),
		'' lower level means we're done and the parent call will
		'' continue. The first call will start with level 0.
		var oplevel = cprecedence(op)
		if oplevel < level then
			exit do
		end if
		'' Left associative?
		if op <> ASTKIND_IIF then
			oplevel += 1
		end if

		'' operator
		x += 1

		dim b as CPPVALUE

		select case op
		case ASTKIND_CLOGOR  '' ||
			'' Parse rhs (don't evaluate if lhs was true)
			parseExpr(b, dtype_only or (a.vali <> 0), oplevel)
			a.vali = iif(a.vali, 1, iif(b.vali, 1, 0))
			a.dtype = TYPE_LONGINT  '' || always produces a signed int

		case ASTKIND_CLOGAND  '' &&
			'' Parse rhs (don't evaluate if lhs was false)
			parseExpr(b, dtype_only or (a.vali = 0), oplevel)
			a.vali = iif(a.vali, iif(b.vali, 1, 0), 0)
			a.dtype = TYPE_LONGINT  '' && always produces a signed int

		case ASTKIND_IIF
			'' Parse 2nd operand (don't evaluate if condition = false)
			parseExpr(b, dtype_only or (a.vali = 0), oplevel)

			'' ':'?
			tkExpect(x, TK_COLON, "for a?b:c iif operator")
			x += 1

			'' Parse 3rd operand (don't evaluate if condition = true)
			dim c as CPPVALUE
			parseExpr(c, dtype_only or (a.vali <> 0), oplevel)

			a.vali = iif(a.vali, b.vali, c.vali)
			a.dtype = max(b.dtype, c.dtype)

		case else
			'' Parse rhs
			parseExpr(b, dtype_only, oplevel)

			'' If one operand is unsigned, promote both operands to unsigned.
			'' This also takes care of the result type, except for relational BOPs,
			'' which are handled below.
			a.dtype = max(a.dtype, b.dtype)

			if dtype_only = FALSE then
				select case op
				case ASTKIND_DIV, ASTKIND_MOD
					if b.vali = 0 then
						tkOops(x, "division by zero")
					end if
				end select

				if a.dtype = TYPE_ULONGINT then
					select case as const op
					case ASTKIND_OR  : a.vali =   cunsg(a.vali) or  cunsg(b.vali)
					case ASTKIND_XOR : a.vali =   cunsg(a.vali) xor cunsg(b.vali)
					case ASTKIND_AND : a.vali =   cunsg(a.vali) and cunsg(b.vali)
					case ASTKIND_CEQ : a.vali = -(cunsg(a.vali) =   cunsg(b.vali))
					case ASTKIND_CNE : a.vali = -(cunsg(a.vali) <>  cunsg(b.vali))
					case ASTKIND_CLT : a.vali = -(cunsg(a.vali) <   cunsg(b.vali))
					case ASTKIND_CLE : a.vali = -(cunsg(a.vali) <=  cunsg(b.vali))
					case ASTKIND_CGT : a.vali = -(cunsg(a.vali) >   cunsg(b.vali))
					case ASTKIND_CGE : a.vali = -(cunsg(a.vali) >=  cunsg(b.vali))
					case ASTKIND_SHL : a.vali =   cunsg(a.vali) shl cunsg(b.vali)
					case ASTKIND_SHR : a.vali =   cunsg(a.vali) shr cunsg(b.vali)
					case ASTKIND_ADD : a.vali =   cunsg(a.vali) +   cunsg(b.vali)
					case ASTKIND_SUB : a.vali =   cunsg(a.vali) -   cunsg(b.vali)
					case ASTKIND_MUL : a.vali =   cunsg(a.vali) *   cunsg(b.vali)
					case ASTKIND_DIV : a.vali =   cunsg(a.vali) \   cunsg(b.vali)
					case ASTKIND_MOD : a.vali =   cunsg(a.vali) mod cunsg(b.vali)
					case else         : assert(FALSE)
					end select
				else
					select case as const op
					case ASTKIND_OR  : a.vali =   a.vali or  b.vali
					case ASTKIND_XOR : a.vali =   a.vali xor b.vali
					case ASTKIND_AND : a.vali =   a.vali and b.vali
					case ASTKIND_CEQ : a.vali = -(a.vali =   b.vali)
					case ASTKIND_CNE : a.vali = -(a.vali <>  b.vali)
					case ASTKIND_CLT : a.vali = -(a.vali <   b.vali)
					case ASTKIND_CLE : a.vali = -(a.vali <=  b.vali)
					case ASTKIND_CGT : a.vali = -(a.vali >   b.vali)
					case ASTKIND_CGE : a.vali = -(a.vali >=  b.vali)
					case ASTKIND_SHL : a.vali =   a.vali shl b.vali
					case ASTKIND_SHR : a.vali =   a.vali shr b.vali
					case ASTKIND_ADD : a.vali =   a.vali +   b.vali
					case ASTKIND_SUB : a.vali =   a.vali -   b.vali
					case ASTKIND_MUL : a.vali =   a.vali *   b.vali
					case ASTKIND_DIV : a.vali =   a.vali \   b.vali
					case ASTKIND_MOD : a.vali =   a.vali mod b.vali
					case else         : assert(FALSE)
					end select
				end if
			end if

			'' Relational BOPs always produce a signed int
			select case op
			case ASTKIND_CEQ, ASTKIND_CNE, _
			     ASTKIND_CLT, ASTKIND_CLE, _
			     ASTKIND_CGT, ASTKIND_CGE
				a.dtype = TYPE_LONGINT
			end select
		end select
	loop
end sub

function CppContext.checkForMacroCall(byval y as integer) as DefineInfo ptr
	assert(tkGet(y) >= TK_ID)
	var id = tkSpellId(y)

	'' Is this id a macro?
	var definfo = lookupMacro(id)
	if definfo = NULL then
		return NULL
	end if

	'' Only expand if not marked otherwise
	if api->idopt(OPT_NOEXPAND).matches(id) or _
	   (tkGetFlags(y) and TKFLAG_NOEXPAND) or _
	   (definfo->macro->attrib and ASTATTRIB_POISONED) then
		return NULL
	end if

	function = definfo
end function

const MAXARGS = 128

private sub hParseMacroCallArgs _
	( _
		byref x as integer, _
		byval macro as AstNode ptr, _
		byval argbegin as integer ptr, _
		byval argend as integer ptr, _
		byref argcount as integer _
	)

	'' Note: The macro call argument list must be parsed without doing
	'' macro expansion. Each argument individually must be expanded later,
	'' but not before the list has been parsed & split up into individual
	'' arguments. I.e. the commas or closing ')' cannot come from macro
	'' expansions.

	var is_variadic = ((macro->attrib and ASTATTRIB_VARIADIC) <> 0)

	'' For each arg in the input...
	var reached_lastarg = FALSE
	do
		if argcount >= MAXARGS then
			tkOops(x, "macro call arg buffer too small, MAXARGS=" & MAXARGS)
		end if

		argbegin[argcount] = x

		'' Is this the argument for the last parameter of a variadic macro?
		'' We're going to read all the remaining tokens into this last argument,
		'' even commas, thus there won't be any other arguments following after this one.
		assert((not is_variadic) or (not reached_lastarg))
		reached_lastarg = (argcount = (macro->paramcount - 1))

		'' For each token that's part of this arg...
		var level = 0
		do
			select case tkGet(x)
			case TK_LPAREN
				level += 1

			case TK_RPAREN
				if level <= 0 then
					exit do
				end if
				level -= 1

			case TK_COMMA
				'' A toplevel comma ends the current arg, unless it's a "..." vararg,
				'' which just "absorbs" everything until the closing ')'.
				if level <= 0 then
					if (not is_variadic) or (not reached_lastarg) then
						exit do
					end if
				end if

			case TK_EOF
				tkOopsExpected(x, "')' to close macro call argument list")
			end select

			x += 1
		loop

		argend[argcount] = x - 1
		argcount += 1

		'' ','?
		if tkGet(x) <> TK_COMMA then
			exit do
		end if
		x += 1
	loop

	'' It's ok to omit the arg(s) for the variadic parameter of a variadic macro.
	if is_variadic and (not reached_lastarg) then
		if argcount >= MAXARGS then
			tkOops(x, "macro call arg buffer too small, MAXARGS=" & MAXARGS)
		end if
		argbegin[argcount] = x
		argend[argcount] = x - 1
		argcount += 1
	end if

	'' Not the expected amount of args?
	if argcount <> macro->paramcount then
		dim s as string
		if argcount > macro->paramcount then
			s = "too many"
		else
			s = "not enough"
		end if
		s += " arguments for '" + *macro->text + "' macro call: "
		s &= argcount & " given, " & macro->paramcount & " needed"
		tkOops(x, s)
	end if
end sub

private function hParseMacroCall _
	( _
		byval x as integer, _
		byval macro as AstNode ptr, _
		byval argbegin as integer ptr, _
		byval argend as integer ptr, _
		byref argcount as integer _
	) as integer

	var begin = x

	'' ID
	assert(tkGet(x) >= TK_ID)
	x += 1

	argcount = -1

	'' Not just "#define m"?
	if macro->paramcount >= 0 then
		'' '('?
		if tkGet(x) <> TK_LPAREN then
			return -1
		end if
		x += 1

		argcount = 0

		'' Not just "#define m()"?
		if macro->paramcount > 0 then
			'' Parse the argument list and fill the argbegin() and
			'' argend() arrays accordingly
			hParseMacroCallArgs(x, macro, argbegin, argend, argcount)
		end if

		'' ')'?
		tkExpect(x, TK_RPAREN, "to close macro call argument list")
		x += 1
	end if

	function = x - 1
end function

'' DEFINED ['('] Identifier [')']
private sub hSkipDefinedUop(byref x as integer)
	assert(tkGet(x) = KW_DEFINED)
	x += 1

	'' '('?
	var have_lparen = FALSE
	if tkGet(x) = TK_LPAREN then
		have_lparen = TRUE
		x += 1
	end if

	'' Identifier? (not doing any expansion here)
	if tkGet(x) >= TK_ID then
		x += 1
	end if

	'' ')'?
	if have_lparen then
		if tkGet(x) = TK_RPAREN then
			x += 1
		end if
	end if
end sub

private sub hWrapInTkBeginEnd(byval first as integer, byval last as integer)
	assert(first <= last)
	tkInsert(first, TK_BEGIN)
	last += 1
	tkInsert(last + 1, TK_END)
end sub

private sub hUnwrapTkBeginEnd(byval first as integer, byval last as integer)
	assert(tkGet(first) = TK_BEGIN)
	assert(tkGet(last) = TK_END)
	tkRemove(first, first)
	last -= 1
	tkRemove(last, last)
end sub

function CppContext.expandInTkBeginEnd(byval y as integer, byval inside_ifexpr as integer) as integer
	assert(tkGet(y) = TK_BEGIN)

	do
		select case tkGet(y)
		case TK_END
			exit do

		case KW_DEFINED
			'' If inside an #if condition expression, don't expand symbols behind the defined operator.
			'' According to the C standard, the handling of defined's that result from macro expansion
			'' is undefined, but gcc handles them as normal defined's, so we do too.
			if inside_ifexpr then
				hSkipDefinedUop(y)
				y -= 1
			end if

		case is >= TK_ID
			if maybeExpandMacro(y, inside_ifexpr, TRUE) then
				'' TK_ID replaced by macro body - reparse
				y -= 1
			end if
		end select

		y += 1
	loop

	function = y
end function

function CppContext.expandInRange _
	( _
		byval first as integer, _
		byval last as integer, _
		byval inside_ifexpr as integer _
	) as integer

	'' Do nothing if range is empty - happens when expanding in a macro
	'' expansion but the expansion is empty, or when expanding in an #if
	'' condition but it's missing.
	if first > last then
		return last
	end if

	'' Insert TK_BEGIN/TK_END around the argument's tokens, to prevent the
	'' macro call parsing functions from reading out-of-bounds.
	hWrapInTkBeginEnd(first, last)
	last += 2
	assert(tkGet(last) = TK_END)

	'' Expand anything in the range
	last = expandInTkBeginEnd(first, inside_ifexpr)

	'' Remove TK_BEGIN/TK_END again
	hUnwrapTkBeginEnd(first, last)
	last -= 2

	function = last
end function

'' Set or unset the BEHINDSPACE flag of a token
private sub hOverrideBehindspace(byval x as integer, byval flag as integer)
	tkSetFlags(x, (tkGetFlags(x) and (not TKFLAG_BEHINDSPACE)) or flag)
end sub

''
'' - Macro arguments must be inserted in place of macro parameters, and fully
''   macro-expanded, but only self-contained without help from tokens outside
''   the argument.
''
'' - Arguments used with # mustn't be macro-expanded, and for arguments used
''   with ##, the last/first token musn't be macro-expanded depending on whether
''   the parameter was on the lhs/rhs of the ## (but the rest of the argument's
''   tokens that aren't used by the ##, if any, must be macro-expanded).
''   I.e. macro expansion mustn't be done when parsing the arguments, but later
''   when inserting them in place of parameters, with the given restrictions.
''
'' - # or ## tokens coming from arguments must not be treated as stringify/merge
''   operators. This must be done only for # or ## in the macro body.
''
'' - #stringify operations must be solved before ## merging (e.g. <L ## #param>
''   becomes <L"argtext">)
''
'' - ## operands may be empty: if an argument is used with ##, but the argument
''   is empty, then the ## doesn't merge anything. ## with 2 empty operands
''   is removed completely. Macro body token(s) preceding/following the ##
''   operand are not taken into account for the merge. Empty ## operand doesn't
''   cause preceding/following tokens to be used instead.
''
'' - If a macro parameter expands to multiple tokens, ## affects the last/first
''   token from the lhs/rhs operands respectively, but not all the tokens
''   inserted in place of the parameter(s).
''
function CppContext.insertMacroExpansion _
	( _
		byval callbehindspace as integer, _
		byval expansionbegin as integer, _
		byref definfo as DefineInfo, _
		byval argbegin as integer ptr, _
		byval argend as integer ptr, _
		byval argcount as integer, _
		byval inside_ifexpr as integer _
	) as integer

	'' Insert the macro body tokens from AST into the tk buffer, surrounded
	'' with TK_BEGIN/TK_END, to allow the code below to read "out-of-bounds"
	'' by -1 or +1, which simplifies handling of # and ## operators.
	''
	'' Having the TK_END also removes the need to keep track of the end of
	'' the expansion through all the insertions/deletions done here.
	'' Instead, if we need to know the end of the expansion, we can just
	'' look for the TK_END.
	tkInsert(expansionbegin, TK_END)
	definfo.copyBody(expansionbegin)
	tkInsert(expansionbegin, TK_BEGIN)

	'' Update the BEHINDSPACE status of the first token in the expansion to
	'' be the same as that of the macro name which we're expanding
	hOverrideBehindspace(expansionbegin + 1, callbehindspace)

	'' Solve #stringify operators (higher priority than ##, and no macro
	'' expansion done for the arg)
	var y = expansionbegin + 1
	while tkGet(y) <> TK_END

		'' '#param'?
		if tkGet(y) = TK_HASH then
			'' Followed by identifier?
			if tkGet(y + 1) >= TK_ID then
				'' Is it a macro parameter?
				var arg = astLookupMacroParam(definfo.macro, tkSpellId(y + 1))
				if arg >= 0 then
					'' Remove #param, and insert stringify result instead
					'' but preserve BEHINDSPACE status.
					assert((arg >= 0) and (arg < argcount))
					var behindspace = tkGetFlags(y) and TKFLAG_BEHINDSPACE
					tkRemove(y, y + 1)

					'' " must be replaced by \"
					'' then we can wrap the stringified text in "..." to produce the TK_STRING
					var s = tkSpell(argbegin[arg], argend[arg])
					s = strReplace(s, """", $"\""")
					s = """" + s + """"

					tkInsert(y, TK_STRING, s)
					hOverrideBehindspace(y, behindspace)
				end if
			end if
		end if

		y += 1
	wend

	'' Replace ## tokens by special internal merge operator tokens, so that
	'' ## tokens from macro arguments aren't mistaken for merge operators.
	y = expansionbegin + 1
	while tkGet(y) <> TK_END

		'' '##'?
		if tkGet(y) = TK_HASHHASH then
			tkInsert(y, TK_PPMERGE)
			var z = y + 1
			tkSetLocation(y, tkGetLocation(z))
			tkRemove(z, z)
		end if

		y += 1
	wend

	'' Insert args into params, surrounded with TK_ARGBEGIN/END, so that
	'' - we know when an arg was empty when doing ## merging (to avoid
	''   merging with other tokens outside the arg),
	'' - we know the arg's boundaries for macro-expanding it later. (must be
	''   done after merging, because only the unmerged tokens of an arg
	''   shall be macro-expanded, and not the ones involved in merging)
	y = expansionbegin + 1
	while tkGet(y) <> TK_END

		'' Macro parameter?
		if tkGet(y) >= TK_ID then
			var arg = astLookupMacroParam(definfo.macro, tkSpellId(y))
			if arg >= 0 then
				'' >= TK_ID
				var behindspace = tkGetFlags(y) and TKFLAG_BEHINDSPACE
				tkRemove(y, y)

				'' TK_ARGBEGIN
				tkInsert(y, TK_ARGBEGIN)
				y += 1

				'' arg's tokens
				tkCopy(y, argbegin[arg], argend[arg], DEFINEBODY_FLAGMASK)
				hOverrideBehindspace(y, behindspace)
				y += argend[arg] - argbegin[arg] + 1

				'' TK_ARGEND
				tkInsert(y, TK_ARGEND)
			end if
		end if

		y += 1
	wend

	''
	'' Do '##' merging
	''
	'' It's not clear how <a ## ## b> or <a ## b ## c> should be processed
	'' (undefined behaviour), so fbfrog shows an error about the first
	'' (cannot merge a and ##) and processes the 2nd as (a##b)##c, i.e.
	'' left-associative.
	''
	y = expansionbegin + 1
	while tkGet(y) <> TK_END

		'' '##' from original macro body (and not '##' from a macro argument)?
		if tkGet(y) = TK_PPMERGE then

			'' 1. If lhs/rhs of '##' were params, then now there will be TK_ARGBEGIN,...,TK_ARGEND sequences.
			'' Move last/first token out of the arg boundaries, so that they end up right next to the '##'.
			'' (can just move the TK_ARGEND/TK_ARGBEGIN respectively, that's easier & faster)
			''
			'' Example with arg on both sides:
			'' from:
			''    [argbegin] a b [argend] ## [argbegin] c d [argend]
			'' to:
			''    [argbegin] a [argend] b ## c [argbegin] d [argend]
			''
			'' If this causes an TK_ARGBEGIN/END to become empty, it must be removed,
			'' so that it won't be misinterpreted as empty arg operand for a following ## operator:
			'' from:
			''    [argbegin] a [argend] ## [argbegin] b [argend] ## [argbegin] c [argend]
			'' to:
			''    a##b ## [argbegin] c [argend]
			'' in order to avoid the situation where the 2nd ##'s lhs seems to be an empty arg:
			''    [argbegin] [argend] a ## b [argbegin] [argend] ## [argbegin] c [argend]
			'' because actually the merged "ab" token is supposed to be 2nd ##'s lhs.

			'' lhs was a non-empty arg?
			if (tkGet(y - 1) = TK_ARGEND) and (tkGet(y - 2) <> TK_ARGBEGIN)  then
				tkRemove(y - 1, y - 1)
				tkInsert(y - 2, TK_ARGEND)
				assert(tkGet(y) = TK_PPMERGE)
				assert(tkGet(y - 1) <> TK_ARGEND)
				assert(tkGet(y - 2) = TK_ARGEND)

				'' Empty now? Then remove the TK_ARGBEGIN/END
				if tkGet(y - 3) = TK_ARGBEGIN then
					tkRemove(y - 3, y - 2)
					y -= 2
				end if
			end if

			'' rhs was a non-empty arg?
			if (tkGet(y + 1) = TK_ARGBEGIN) and (tkGet(y + 2) <> TK_ARGEND) then
				tkRemove(y + 1, y + 1)
				tkInsert(y + 2, TK_ARGBEGIN)
				assert(tkGet(y) = TK_PPMERGE)
				assert(tkGet(y + 1) <> TK_ARGBEGIN)
				assert(tkGet(y + 2) = TK_ARGBEGIN)

				'' Empty now? Then remove the TK_ARGBEGIN/END
				if tkGet(y + 3) = TK_ARGEND then
					tkRemove(y + 2, y + 3)
				end if
			end if

			assert(tkGet(y) = TK_PPMERGE)
			var l = y - 1
			var r = y + 1

			'' If one operand was an empty arg, then no merging needs to be done,
			'' the other operand can just be preserved as-is; or in case both were
			'' empty, the ## just disappears.

			'' Non-empty on both sides?
			if (tkGet(l) <> TK_ARGEND) and (tkGet(r) <> TK_ARGBEGIN) then
				if tkGet(l) = TK_BEGIN then
					tkOops(y, "## merge operator at beginning of macro body, missing operand to merge with")
				end if
				if tkGet(r) = TK_END then
					tkOops(y, "## merge operator at end of macro body, missing operand to merge with")
				end if

				'' Combine the original text representation of both tokens,
				'' and prepend a space if the lhs was BEHINDSPACE, such that
				'' the merged token will also be BEHINDSPACE.
				dim mergetext as string
				if tkGetFlags(l) and TKFLAG_BEHINDSPACE then
					mergetext += " "
				end if
				mergetext += tkSpell(l) + tkSpell(r)

				'' and try to lex them
				var z = tkGetCount()
				lexLoadC(z, mergetext, sourceinfoForZstring("## merge operation"))

				'' That should have produced only 1 token. If it produced more, then the merge failed.
				assert(tkGetCount() >= (z + 1))
				if tkGetCount() > (z + 1) then
					tkRemove(z, tkGetCount() - 1)
					tkOops(y, "## merge operator cannot merge '" + tkSpell(y - 1) + "' and '" + tkSpell(y + 1) + "'")
				end if

				'' Remove the 3 (l ## r) tokens and insert the merged token in place of l
				tkRemove(l, r)
				z -= 3
				y = l

				tkCopy(y, z, z, DEFINEBODY_FLAGMASK)
				z += 1

				tkRemove(z, z)
			else
				'' Just remove the '##'
				tkRemove(y, y)
				y -= 1
			end if
		end if

		y += 1
	wend

	'' Recursively macro-expand the tokens in each TK_ARGBEGIN/END sequence,
	'' and then remove TK_ARGBEGIN/END.
	y = expansionbegin + 1
	while tkGet(y) <> TK_END

		'' Macro parameter?
		if tkGet(y) = TK_ARGBEGIN then
			var z = y
			do
				z += 1
			loop while tkGet(z) <> TK_ARGEND

			'' Macro-expand the arg's tokens
			z = expandInRange(y, z, inside_ifexpr)

			'' Remove TK_ARGBEGIN/END wrapping
			assert(tkGet(y) = TK_ARGBEGIN)
			tkRemove(y, y)
			y -= 1
			z -= 1
			assert(tkGet(z) = TK_ARGEND)
			tkRemove(z, z)
			z -= 1

			y = z
		end if

		y += 1
	wend

	'' Remove the TK_BEGIN/END wrapping around the expansion
	assert(tkGet(expansionbegin) = TK_BEGIN)
	tkRemove(expansionbegin, expansionbegin)
	y -= 1
	assert(tkGet(y) = TK_END)
	tkRemove(y, y)
	y -= 1

	function = y
end function

sub CppContext.expandMacro _
	( _
		byref definfo as DefineInfo, _
		byval callbegin as integer, _
		byval callend as integer, _
		byval argbegin as integer ptr, _
		byval argend as integer ptr, _
		byval argcount as integer, _
		byval inside_ifexpr as integer, _
		byval expand_recursively as integer _
	)

	'' Insert the macro body behind the call (this way the positions
	'' stored in argbegin()/argend() stay valid)
	var expansionbegin = callend + 1
	var expansionend = insertMacroExpansion( _
			tkGetFlags(callbegin) and TKFLAG_BEHINDSPACE, _
			expansionbegin, definfo, argbegin, argend, argcount, inside_ifexpr)

	'' Mark expansion tokens
	tkAddFlags(expansionbegin, expansionend, TKFLAG_EXPANSION)

	if expand_recursively then
		'' Recursively do macro expansion in the expansion
		'' - Marking the current macro as poisoned, so it won't be expanded
		''   again within the expansion, preventing expansion of complete
		''   recursive calls.
		'' - Incomplete recursive calls need to be marked with NOEXPAND so they
		''   won't be expanded later when they become complete by taking into
		''   account tokens following behind the expansion.
		definfo.macro->attrib or= ASTATTRIB_POISONED
		expansionend = expandInRange(expansionbegin, expansionend, inside_ifexpr)
		definfo.macro->attrib and= not ASTATTRIB_POISONED
	end if

	'' Disable future expansion of recursive macro calls to this macro
	'' (those that weren't expanded due to the "poisoning")
	scope
		var y = expansionbegin
		while y <= expansionend

			if tkGet(y) >= TK_ID then
				'' Known macro, and it's the same as this one?
				var calldefinfo = checkForMacroCall(y)
				if calldefinfo = @definfo then
					'' Can the macro call be parsed successfully,
					'' and is it fully within the expansion?
					dim as integer argbegin(0 to MAXARGS-1)
					dim as integer argend(0 to MAXARGS-1)
					dim as integer argcount
					var callend = hParseMacroCall(y, definfo.macro, @argbegin(0), @argend(0), argcount)
					if (callend >= 0) and (callend <= expansionend) then
						tkAddFlags(y, y, TKFLAG_NOEXPAND)
					end if
				end if
			end if

			y += 1
		wend
	end scope

	'' Update locations on the expansion tokens to point to the macro call,
	'' instead of the #define body etc.
	scope
		var y = expansionbegin
		while y <= expansionend
			tkSetLocation(y, tkGetLocation(callbegin))
			y += 1
		wend
	end scope

	'' Then remove the call tokens
	tkRemove(callbegin, callend)
end sub

function CppContext.maybeExpandMacro(byval y as integer, byval inside_ifexpr as integer, byval expand_recursively as integer) as integer
	var definfo = checkForMacroCall(y)
	if definfo = NULL then
		exit function
	end if

	dim as integer argbegin(0 to MAXARGS-1)
	dim as integer argend(0 to MAXARGS-1)
	dim as integer argcount

	'' Try to parse the macro call (can fail in case of function-like macro
	'' without argument list)
	var callbegin = y
	var callend = hParseMacroCall(callbegin, definfo->macro, @argbegin(0), @argend(0), argcount)
	if callend < 0 then
		exit function
	end if

	expandMacro(*definfo, callbegin, callend, @argbegin(0), @argend(0), argcount, inside_ifexpr, expand_recursively)
	function = TRUE
end function

function CppContext.getFileContext() as CppStackNode ptr
	for i as integer = level to 0 step -1
		var ctx = @stack(i)
		if ctx->state = STATE_FILE then
			return ctx
		end if
	next
	assert(FALSE)
end function

sub CppContext.push(byval state as integer, byval knownfile as integer = -1)
	assert(iif(knownfile >= 0, state = STATE_FILE, TRUE))

	level += 1
	if level >= MAXSTACK then
		tkOops(x, "#if/#include stack too small, MAXSTACK=" & MAXSTACK)
	end if

	with stack(level)
		.state = state
		.knownfile = knownfile
		.incdir = NULL
	end with

	if state = STATE_FILE then
		filelevel += 1
	end if
end sub

sub CppContext.pop()
	'' Finished parsing a file?
	with stack(level)
		if .state = STATE_FILE then
			filelevel -= 1
			if .knownfile >= 0 then
				files[.knownfile].guardstate = GUARDSTATE_KNOWN
			end if
		end if
	end with
	level -= 1
end sub

sub CppContext.applyIf(byval condition as integer)
	if condition then
		'' #if TRUE, don't skip
		stack(level).state = STATE_TRUE
		skiplevel = MAXSTACK  '' needed for #elif, in case we were skipping previously
	else
		'' #if FALSE, start skipping (or in case of #elif, possibly continue)
		skiplevel = level
	end if
end sub

private function hSkipEols(byval x as integer) as integer
	while tkGet(x) = TK_EOL
		x += 1
	wend
	function = x
end function

function CppContext.parseIfExpr() as integer
	'' Expand macros in the #if condition before parsing it
	'' * but don't expand operands of the "defined" operator
	'' * we allow "defined" operators to be produced by
	''   macro expansion, like gcc
	expandInRange(x, hSkipToEol(x) - 1, TRUE)

	'' Try to parse and evaluate an expression
	dim value as CPPVALUE
	parseExpr(value, FALSE)
	function = (value.vali <> 0)
end function

sub CppContext.parseIf()
	push(STATE_IF)
	x += 1

	if isSkipping() then
		exit sub
	end if

	'' Condition expression
	applyIf(parseIfExpr())

	parseEol()
end sub

sub CppContext.parseIfdef(byval directivekw as integer)
	push(STATE_IF)
	x += 1

	if isSkipping() then
		exit sub
	end if

	'' Identifier
	if tkGet(x) < TK_ID then
		tkExpect(x, TK_ID, "behind " + tkInfoPretty(directivekw))
	end if
	var id = tkSpellId(x)
	checkForUnknownSymbol(id)
	x += 1

	var condition = isMacroCurrentlyDefined(id)
	if directivekw = KW_IFNDEF then
		condition = not condition
	end if
	applyIf(condition)

	parseEol()
end sub

'' Forget the guard (if any) for the current file context
'' It's possible that we're in a recursive #include, but it doesn't matter,
'' we'll just try to disable it's #include guard optimization multiple times.
sub CppContext.disableIncludeGuardOptimization()
	assert(level >= 1)
	assert(stack(level-1).state = STATE_FILE)
	var knownfile = stack(level-1).knownfile
	if knownfile >= 0 then
		with files[knownfile]
			if .guard then
				assert(.guardstate = GUARDSTATE_CHECKING)
				deallocate(.guard)
				.guard = NULL
			end if
		end with
	end if
end sub

'' Check whether we're inside the first nesting level inside a file
'' (for example, an #include guard)
function CppContext.isInsideFileLevelBlock() as integer
	assert(stack(level).state <> STATE_FILE)
	if level >= 1 then
		function = (stack(level-1).state = STATE_FILE)
	end if
end function

sub CppContext.parseElseIf()
	'' Verify #elif usage even if skipping
	select case stack(level).state
	case is < STATE_IF
		tkOops(x, "#elif without #if")
	case STATE_ELSE
		tkOops(x, "#elif after #else")
	end select
	x += 1

	if isInsideFileLevelBlock() then
		disableIncludeGuardOptimization()
	end if

	'' Evaluate condition in case it matters:
	''    a) not yet skipping,
	''    b) skipping due to a previous #if/#elif FALSE
	if (skiplevel = MAXSTACK) or (skiplevel = level) then
		'' But not if there already was an #if/#elif TRUE on this level
		'' (then this #elif isn't reached)
		if stack(level).state = STATE_TRUE then
			'' Start/continue skipping
			skiplevel = level
		else
			'' Condition expression
			applyIf(parseIfExpr())
			parseEol()
		end if
	end if
end sub

sub CppContext.parseElse()
	'' Verify #else usage even if skipping
	select case stack(level).state
	case is < STATE_IF
		tkOops(x, "#else without #if")
	case STATE_ELSE
		tkOops(x, "#else after #else")
	end select
	x += 1

	if isInsideFileLevelBlock() then
		disableIncludeGuardOptimization()
	end if

	parseEol()

	'' Check whether to skip this #else or not, if
	''    a) not yet skipping,
	''    b) skipping due to a previous #if/#elif FALSE
	if (skiplevel = MAXSTACK) or (skiplevel = level) then
		if stack(level).state = STATE_TRUE then
			'' Previous #if/#elseif TRUE, skip #else
			skiplevel = level
		else
			'' Previous #if/#elseif FALSE, don't skip #else
			skiplevel = MAXSTACK
		end if
	end if

	stack(level).state = STATE_ELSE
end sub

sub CppContext.parseEndIf()
	if stack(level).state < STATE_IF then
		tkOops(x, "#endif without #if")
	end if
	x += 1

	parseEol()

	if isInsideFileLevelBlock() then
		'' If we don't reach the #include EOF directly after the #endif,
		'' then this can't be an #include guard
		if tkGet(hSkipEols(x)) <> TK_ENDINCLUDE then
			assert(tkGet(hSkipEols(x)) <> TK_EOF)
			disableIncludeGuardOptimization()
		end if
	end if

	'' If skipping due to current level, then stop skipping.
	if skiplevel = level then
		skiplevel = MAXSTACK
	end if

	pop()
end sub

sub CppContext.maybePrintIncludeTree(byref inctext as string, byref prettyfile as string, byval include_skipped as integer)
	if frog.verbose then
		var s = string(filelevel, ".") + " "
		if include_skipped then s += "("
		s += inctext
		if prettyfile <> inctext then
			s += " => " + prettyfile
		end if
		if include_skipped then s += ")"
		print s
	end if
end sub

'' Search for #included files in one of the parent directories of the context
'' file. Usually the #include will refer to a file in the same directory or in
'' a sub-directory at the same level or some levels up.
function CppContext.searchHeaderFile _
	( _
		byref contextfile as string, _
		byval contextincdir as AstNode ptr, _
		byref inctext as string, _
		byval is_system_include as integer, _
		byref incdir as AstNode ptr _
	) as string

	'' If #including by absolute path, use it as-is
	if pathIsAbsolute(inctext) then
		return inctext
	end if

	'' Relative to context file, unless it was #include <...> or #include_next
	if (contextincdir = NULL) and (not is_system_include) then
		var incfile = pathAddDiv(pathOnly(contextfile)) + inctext
		if fileexists(incfile) then
			return incfile
		end if
		maybePrintIncludeTree(inctext, "not found at " + incfile, FALSE)
	end if

	'' In any of the include search directories; #include_next starts with
	'' the incdir following the one where the parent file was found
	var i = iif(contextincdir, contextincdir->nxt, incdirs->head)
	while i

		var incfile = pathAddDiv(*i->text) + inctext
		if fileexists(incfile) then
			incdir = i
			return incfile
		end if
		maybePrintIncludeTree(inctext, "not found at " + incfile, FALSE)

		i = i->nxt
	wend

	function = ""
end function

'' Check for the typical #include guard header:
''    #ifndef ID <EOL> #define ID ...
private function hDetectIncludeGuardBegin(byval first as integer) as zstring ptr
	assert(tkGet(first - 1) = TK_EOL)

	var x = hSkipEols(first)

	if tkGet(x) <> TK_HASH then exit function
	x += 1
	if tkGet(x) <> KW_IFNDEF then exit function
	x += 1
	if tkGet(x) <> TK_ID then exit function
	var id1 = tkGetText(x)
	x += 1
	if tkGet(x) <> TK_EOL then exit function
	x += 1
	if tkGet(x) <> TK_HASH then exit function
	x += 1
	if tkGet(x) <> KW_DEFINE then exit function
	x += 1
	if tkGet(x) <> TK_ID then exit function
	var id2 = tkGetText(x)
	if *id1 <> *id2 then exit function

	function = id1
end function

'' "filename" | <filename>
'' Escape sequences in "filename" are not evaluated.
'' TODO: Don't evaluate escape sequences/comments in <filename>
function CppContext.parseIncludeFilename(byref is_system_include as integer) as string
	select case tkGet(x)
	case TK_LT
		'' <filename>
		is_system_include = TRUE

		'' Skip tokens until the '>'
		var begin = x
		do
			x += 1
			select case tkGet(x)
			case TK_GT
				exit do
			case TK_EOL, TK_EOF
				tkOops(x, "missing '>' to finish #include <...")
			end select
		loop

		'' Then spell them to get the filename
		function = tkSpell(begin + 1, x - 1)
		x += 1

	case TK_STRING
		'' "filename"
		function = parseStringLiteral(FALSE)

	case else
		tkOopsExpected(x, """filename"" or <filename> behind #include")
	end select
end function

sub CppContext.parseInclude(byval begin as integer, byref flags as integer, byval is_include_next as integer)
	x += 1

	assert(isSkipping() = FALSE)

	'' Expand macros behind the #include (but still in the same line)
	'' but only if there is not already a " or < (like gcc).
	'' This way we avoid expanding macros inside <...> which can't be made
	'' a single token like "..." because it depends on context. It should
	'' only be a single token if used for an #include, but if it's written
	'' in a #define body then we don't know what the context will be.
	select case tkGet(x)
	case TK_LT, TK_STRING
	case else
		expandInRange(x, hSkipToEol(x) - 1, FALSE)
	end select

	'' "filename" | <filename>
	var location = tkGetLocation(x)
	var includetkflags = tkGetFlags(x)
	var is_system_include = FALSE
	var inctext = parseIncludeFilename(is_system_include)

	parseEol()

	dim incfile as string
	dim incdir as AstNode ptr
	if includetkflags and TKFLAG_ROOTFILE then
		'' No #include file search for internal #includes
		incfile = inctext
	else
		'' #include file search
		dim contextfile as string
		if location.source then
			contextfile = *location.source->name
		end if

		dim contextincdir as AstNode ptr
		if is_include_next then
			contextincdir = getFileContext()->incdir
		end if

		incfile = searchHeaderFile(contextfile, contextincdir, inctext, is_system_include, incdir)
		if len(incfile) = 0 then
			'' #include not found
			api->print(inctext + " (not found)")

			'' Preserve non-internal #includes that weren't found
			if (includetkflags and (TKFLAG_PREINCLUDE or TKFLAG_ROOTFILE)) = 0 then
				flags and= not TKFLAG_REMOVE
			end if

			exit sub
		end if
	end if

	'' Get the normalized representation of the path, for use in hash tables
	'' etc. Otherwise foo.h from the root dir and ../foo.h from a subdir
	'' would be seen as different files.
	incfile = pathNormalize(pathMakeAbsolute(incfile))

	'' * Don't preserve internal #includes,
	'' * don't preserve #includes if we will emit the #included content
	''   into the same .bi file as the #include directive itself.
	''
	'' We do this check here instead of later when distributing declarations
	'' into .bi files, because #include tokens/ASTNODEs don't carry enough
	'' information about the #included file. Knowing the #include "filename"
	'' isn't enough, because it may be a relative path such as "../foo.h".
	''
	'' Not internal?
	if (includetkflags and (TKFLAG_PREINCLUDE or TKFLAG_ROOTFILE)) = 0 then
		assert(location.source->is_file)
		var directivebi = frogLookupBiFromH(location.source->name)
		var contentbi = frogLookupBiFromH(incfile)
		'' Not emitted into same .bi as #included content?
		if directivebi <> contentbi then
			'' Then preserve it
			flags and= not TKFLAG_REMOVE
		end if
	end if

	'' For display we make the filename relative to curdir()
	var prettyfile = pathStripCurdir(incfile)

	var knownfile = lookupOrAppendKnownFile(incfile, prettyfile)
	with files[knownfile]
		'' Did we find a #pragma once in this file previously?
		if .pragmaonce then
			'' Don't #include it again ever
			maybePrintIncludeTree(inctext, prettyfile, TRUE)
			exit sub
		end if

		'' Did we find an #include guard in this file previously?
		if (.guardstate = GUARDSTATE_KNOWN) and (.guard <> NULL) then
			'' Only load the file if the guard symbol isn't defined (anymore) now.
			if isMacroCurrentlyDefined(.guard) then
				'' Skipping header due to include guard
				maybePrintIncludeTree(inctext, prettyfile, TRUE)
				exit sub
			end if
		end if
	end with

	maybePrintIncludeTree(inctext, prettyfile, FALSE)
	api->print(prettyfile)

	'' Push the #include file context
	push(STATE_FILE, knownfile)
	stack(level).incdir = incdir

	'' Read the include file and insert its tokens
	var file = filebuffersAdd(incfile, location)
	var y = lexLoadC(x, file->buffer, file->source)

	'' If tokens were inserted, ensure there is an EOL at the end
	if x < y then
		if tkGet(y - 1) <> TK_EOL then
			tkInsert(y, TK_EOL)
			y += 1
		end if
	end if

	'' Put TK_ENDINCLUDE behind the #include file content, so we can detect
	'' the included EOF and pop the #include context from the cpp.stack.
	tkInsert(y, TK_ENDINCLUDE)
	y += 1

	'' Insert EOL behind the TK_ENDINCLUDE so we can detect BOL there
	tkInsert(y, TK_EOL)
	y += 1

	'' Start parsing the #included content
	assert(tkGet(x - 1) = TK_EOL)
	assert(y <= tkGetCount())
	assert(tkGet(y - 2) = TK_ENDINCLUDE)

	''
	'' Prepare for the include guard optimization
	''
	'' If we didn't check this file for an #include guard yet, and we're
	'' not currently checking already (recursive #includes), then we can
	'' check during this #include context.
	''
	'' Does the #include begin with the typical #include guard header?
	''     #ifndef FOO
	''     #define FOO
	''
	'' We'll store the guard id (if any) for now. If we later find that
	'' there is an #elif/#else, or that we don't reach #include EOF after
	'' the "guard" #endif, then we can mark the include guard optimization
	'' as impossible by setting the guard to NULL.
	'' (see cppDisableIncludeGuardOptimization())
	''
	with files[knownfile]
		if .guardstate = 0 then
			.guardstate = GUARDSTATE_CHECKING
			assert(.guard = NULL)
			.guard = strDuplicate(hDetectIncludeGuardBegin(x))
		end if
	end with
end sub

sub CppContext.parseEndInclude()
	assert(skiplevel = MAXSTACK)
	assert(level > 0)
	if stack(level).state >= STATE_IF then
		tkOops(x - 1, "missing #endif")
	end if
	pop()

	'' Mark the TK_ENDINCLUDE for removal, so they won't get in the way of
	'' C parsing (in case declarations cross #include/file boundaries).
	tkSetRemove(x, x)
	x += 1
end sub

sub CppContext.maybeExpandMacroInDefineBody(byval parentdefine as AstNode ptr)
	var id = tkSpellId(x)

	'' Only expand if the called macro was given with -expandindefine
	if api->idopt(OPT_EXPANDINDEFINE).matches(id) = FALSE then
		exit sub
	end if

	'' Similar to maybeExpandMacro():
	var definfo = checkForMacroCall(x)
	if definfo = NULL then
		exit sub
	end if

	dim as integer argbegin(0 to MAXARGS-1)
	dim as integer argend(0 to MAXARGS-1)
	dim as integer argcount
	var callbegin = x
	var callend = hParseMacroCall(callbegin, definfo->macro, @argbegin(0), @argend(0), argcount)
	if callend < 0 then
		exit sub
	end if

	'' Don't expand if the macrocall involves parameters of the parentdefine
	for i as integer = callbegin to callend
		if tkGet(i) >= TK_ID then
			if astLookupMacroParam(parentdefine, tkSpellId(i)) >= 0 then
				exit sub
			end if
		end if
	next

	expandMacro(*definfo, callbegin, callend, @argbegin(0), @argend(0), argcount, FALSE, FALSE)

	'' TK_ID expanded; reparse it
	x -= 1
end sub

function CppContext.shouldRemoveDefine(byval id as zstring ptr) as integer
	function = api->idopt(OPT_REMOVEDEFINE).matches(id)
end function

'' DEFINE Identifier ['(' ParameterList ')'] Body Eol
sub CppContext.parseDefine(byref flags as integer)
	x += 1

	assert(isSkipping() = FALSE)

	'' Identifier ['(' ParameterList ')']
	var macro = hDefineHead(x)

	'' Body
	var xbody = x

	''
	'' If there are any -expandindefine options, look for corresponding
	'' macros in the #define body, and expand them.
	''
	'' But don't expand macro calls that involve parameters of the #define,
	'' because then we risk wrong expansion:
	''    -expandindefine a
	''    #define a(x) x##1
	''    #define b(x) a(x)
	''    #define c(x) x + a(1)
	'' =>
	''    #define a(x) x##1
	''    #define b(x) x1      // wrong, b() is broken now
	''    #define c(x) x + 11  // ok: invocation of a() doesn't involve x
	''
	if api->idopt(OPT_EXPANDINDEFINE).nonEmpty then
		do
			select case tkGet(x)
			case TK_EOL
				exit do

			case is >= TK_ID
				maybeExpandMacroInDefineBody(macro)

			end select

			x += 1
		loop
	end if

	'' Eol
	var xeol = hSkipToEol(xbody)
	assert(tkGet(xeol) = TK_EOL)
	x = xeol + 1

	var definfo = new DefineInfo
	definfo->xbody = xbody
	definfo->xeol = xeol
	definfo->macro = macro

	if frog.verbose >= 2 then
		print "#define " + *macro->text + " " + tkSpell(xbody, xeol)
	end if

	'' Report conflicting #defines
	var prevdef = lookupMacro(macro->text)
	if prevdef then
		if prevdef->equals(definfo) = FALSE then
			'' TODO: should only report once per symbol (per fbfrog run, not cpp run)
			print "conflicting #define " + *macro->text
		end if
	end if

	addMacro(macro->text, definfo)

	'' Normally, we preserve #define directives (unlike the other CPP directives),
	'' thus no generic tkSetRemove() here. Unless the symbol was registed for removal.
	if shouldRemoveDefine(macro->text) = FALSE then
		flags and= not TKFLAG_REMOVE
	end if
end sub

sub CppContext.parseUndef(byref flags as integer)
	x += 1

	assert(isSkipping() = FALSE)

	'' Identifier
	if tkGet(x) < TK_ID then
		tkExpect(x, TK_ID, "behind #undef")
	end if
	var id = tkSpellId(x)
	x += 1

	if frog.verbose >= 2 then
		print "#undef " + *id
	end if

	addKnownUndefined(id)

	parseEol()

	'' Ditto
	if shouldRemoveDefine(id) = FALSE then
		flags and= not TKFLAG_REMOVE
	end if
end sub

sub CppContext.parsePragmaPushPopMacro(byval is_push as integer)
	x += 1

	var whatfor = iif(is_push, _
		@"for #pragma push_macro(""..."")", _
		@"for #pragma pop_macro(""..."")")

	'' '('
	tkExpect(x, TK_LPAREN, whatfor)
	x += 1

	'' "..."
	tkExpect(x, TK_STRING, whatfor)
	var id = parseStringLiteral(TRUE)

	'' ')'
	tkExpect(x, TK_RPAREN, whatfor)
	x += 1

	if is_push then
		saveMacro(id)
	else
		restoreMacro(id)
	end if
end sub

function CppContext.parsePragma(byref flags as integer) as integer
	select case tkSpell(x)
	'' #pragma once
	case "once"
		x += 1

		var knownfile = getFileContext()->knownfile
		if knownfile >= 0 then
			files[knownfile].pragmaonce = TRUE
		end if

	'' #pragma message("...")
	case "message"
		'' Ignore
		x = hSkipToEol(x)

	'' MSVC:
	'' #pragma comment(lib, "<library file name>")
	case "comment"
		x += 1

		'' '('
		tkExpect(x, TK_LPAREN, "for #pragma comment(...)")
		x += 1

		select case tkSpell(x)
		case "lib"
			x += 1

			'' ','
			tkExpect(x, TK_COMMA, "for #pragma comment(lib, ""..."")")
			x += 1

			'' "..."
			tkExpect(x, TK_STRING, "for #pragma comment(lib, ""..."")")
			x += 1

			'' Preserve the #pragma comment(lib, "...") for the C parser
			flags and= not TKFLAG_REMOVE

		case else
			exit function
		end select

		'' ')'
		tkExpect(x, TK_RPAREN, "for #pragma comment(...)")
		x += 1

	case "GCC"
		x += 1

		select case tkSpell(x)
		case "system_header", "push_options", "pop_options", "reset_options", _
		     "optimize", "target", "visibility", "diagnostic"
			'' Ignore
			x = hSkipToEol(x)

		case else
			exit function
		end select

	case "clang"
		x += 1

		select case tkSpell(x)
		case "diagnostic"
			x = hSkipToEol(x)

		case else
			exit function
		end select

	case "warning"
		'' Ignore
		x = hSkipToEol(x)

	'' #pragma pack(N)
	'' #pragma pack()
	'' #pragma pack(push, N)
	'' #pragma pack(pop)
	case "pack"
		x += 1

		'' Just skip to EOL and let the C parser worry about checking
		'' the syntax
		x = hSkipToEol(x)

		'' Preserve the #pragma pack for the C parser
		flags and= not TKFLAG_REMOVE

	case "push_macro"
		parsePragmaPushPopMacro(TRUE)

	case "pop_macro"
		parsePragmaPushPopMacro(FALSE)

	case else
		exit function
	end select

	parseEol()
	function = TRUE
end function

sub CppContext.parseDirective()
	'' '#'
	var begin = x
	assert(tkGet(x) = TK_HASH)
	x += 1

	var directivekw = tkGet(x)

	'' When skipping, only #if/#elif/#else/#endif directives are handled,
	'' anything else (even invalid directives) must be ignored.
	if isSkipping() then
		select case directivekw
		case KW_IF, KW_IFDEF, KW_IFNDEF, KW_ELIF, KW_ELSE, KW_ENDIF

		case else
			tkSetRemove(begin, x)
			x += 1
			exit sub
		end select
	end if

	'' Marking the '#' here already to get better error messages
	tkAddFlags(begin, begin, TKFLAG_STARTOFDIRECTIVE)

	var flags = TKFLAG_REMOVE or TKFLAG_DIRECTIVE

	select case directivekw
	case KW_IF
		parseIf()

	case KW_IFDEF, KW_IFNDEF
		parseIfdef(directivekw)

	case KW_ELIF
		parseElseIf()

	case KW_ELSE
		parseElse()

	case KW_ENDIF
		parseEndIf()

	case KW_INCLUDE
		parseInclude(begin, flags, FALSE)

	case KW_INCLUDE_NEXT
		parseInclude(begin, flags, TRUE)

	case KW_DEFINE
		parseDefine(flags)

	case KW_UNDEF
		parseUndef(flags)

	case KW_PRAGMA
		x += 1
		if parsePragma(flags) = FALSE then
			tkOops(x, "unknown #pragma")
		end if

	case KW_ERROR
		'' Not using the #error's text as error message,
		'' otherwise it would be mistaken for being generated by fbfrog.
		tkOops(x, "#error")

	case KW_WARNING
		x += 1
		'' ditto
		print tkReport(x, "#warning")
		x = hSkipToEol(x) + 1

	case TK_EOL
		'' '#' followed by EOL (accepted by gcc/clang too)
		x += 1

	case else
		tkOops(x, "unknown PP directive")
	end select

	if flags then
		tkAddFlags(begin, x - 1, flags)
	end if
end sub

sub CppContext.parseNext()
	select case tkGet(x)
	case TK_ENDINCLUDE
		parseEndInclude()
		exit sub

	'' '#'
	case TK_HASH
		'' Parse directive if at BOL and the '#' token isn't the result of a macro expansion
		'' We do this for every "toplevel" '#', before ever doing macro expansion behind it,
		'' so it should be safe to assume that if the '#' isn't coming from a macro expansion,
		'' the rest isn't either.
		if tkIsEolOrEof(x - 1) and tkIsOriginal(x) then
			parseDirective()
			exit sub
		end if

	'' _Pragma("...")
	case KW__PRAGMA
		if isSkipping() = FALSE then
			var begin = x
			x += 1

			'' '('
			tkExpect(x, TK_LPAREN, "behind _Pragma")
			x += 1

			'' StringLiteral
			tkExpect(x, TK_STRING, "inside _Pragma()")
			var text = parseStringLiteral(TRUE)

			'' ')'
			tkExpect(x, TK_RPAREN, "to close _Pragma")
			x += 1

			'' Insert #pragma corresponding to the _Pragma(),
			'' while ensuring to have EOL in front of and behind it,
			'' mark the _Pragma() for removal, then we can parse the
			'' #pragma as usual.
			tkSetRemove(begin, x - 1)
			var pragma = !"\n#pragma " + text
			if tkGet(x) <> TK_EOL then
				pragma += !"\n"
			end if
			lexLoadC(x, pragma, sourceinfoForZstring("_Pragma(" + text + ")"))
			exit sub
		end if

	'' Identifier/keyword? Check whether it needs to be macro-expanded
	case is >= TK_ID
		if isSkipping() = FALSE then
			if maybeExpandMacro(x, FALSE, TRUE) = FALSE then
				'' TK_ID not expanded - skip it (otherwise, we have to reparse it)
				x += 1
			end if
			exit sub
		end if

	'' Remove standalone EOLs, so the C parser doesn't have to handle them
	case TK_EOL
		tkSetRemove(x)
		x += 1
		exit sub
	end select

	'' Some token that doesn't matter to the CPP
	if isSkipping() then
		tkSetRemove(x)
	end if
	x += 1
end sub

sub CppContext.parseToplevel()
	while tkGet(x) <> TK_EOF
		parseNext()
	wend

	'' If anything is left on the stack at EOF, it can only be #ifs
	'' (#includes should be popped due to TK_ENDINCLUDE's already)
	if level > 0 then
		assert(stack(level).state >= STATE_IF)
		tkOops(x, "missing #endif")
	end if
end sub

'' Move CPP directives (the ones preserved for C parsing - #defines and
'' #includes) out of C declarations, so the C parser can treat them as toplevel
'' declarations/statements too.
sub hMoveDirectivesOutOfConstructs()
	var x = 0
	do
		'' Skip any directives at begin of construct
		while tkIsDirective(x)
			x += 1
		wend

		if tkGet(x) = TK_EOF then
			exit do
		end if

		var nxt = hSkipConstruct(x, TRUE)

		'' Exclude directives at end of construct from the construct
		while tkIsDirective(nxt - 1)
			nxt -= 1
		wend
		assert(x < nxt)

		'' Handle directives inside this construct: Move them to the end
		'' and exclude them from the construct.
		var writepos = nxt
		while x < nxt
			if tkIsDirective(x) then
				'' Collect all directives in a row
				var y = x
				while tkIsDirective(y + 1)
					y += 1
				wend
				assert(tkGet(y) = TK_EOL)
				assert(y < nxt)

				'' Move from middle to the end (but behind previously moved
				'' directives, to preserve their order)
				tkCopy(writepos, x, y, -1)
				tkRemove(x, y)

				'' Update end-of-construct position as we're moving
				'' directives out of the current construct
				nxt -= y - x + 1
			else
				x += 1
			end if
		wend
	loop
end sub

private function removeEols(byval first as integer, byval last as integer) as integer
	var x = first
	while x <= last
		if tkGet(x) = TK_EOL then
			tkRemove(x, x)
			x -= 1
			last -= 1
		end if
		x += 1
	wend
	function = last
end function

sub hApplyReplacements(byref api as ApiInfo)
	'' Lex all the C token "patterns", so we can use tkCTokenRangesAreEqual()
	'' Insert them at the front of the tk buffer, because
	''  * they have to go *somewhere*
	''  * then we can easily skip them when searching through the main tokens,
	''    without having to worry about confusing them with real constructs...
	''  * then inserting/removing tokens from the main part won't affect our
	''    offsets into the pattern part
	var x = 0
	for i as integer = 0 to api.replacementcount - 1
		var begin = x
		x = lexLoadC(x, api.replacements[i].fromcode, sourceinfoForZstring("C code pattern from replacements file"))

		'' But remove EOLs from the patterns, because we're going to match against tk buffer content
		'' after the CPP phase, i.e. which had its EOLs removed aswell (except for #directives)
		x = removeEols(begin, x)

		api.replacements[i].patternlen = x - begin
	next
	var xmainbegin = x

	'' Search & replace
	x = xmainbegin
	while tkGet(x) <> TK_EOF
		var nxt = hSkipConstruct(x, FALSE)

		'' Compare the construct's tokens against tokens of the C code
		'' pattern given in the replacements file.
		''  * comparing based on tokens, so whitespace doesn't matter

		'' For CPP directives, exclude the EOL from the comparison,
		'' because the C code patterns don't include the \n either.
		var last = nxt - 1
		assert(x <= last)
		if tkIsDirective(x) and (tkGet(last) = TK_EOL) then
			last -= 1
		end if

		var constructlen = last - x + 1
		var patternbegin = 0

		for i as integer = 0 to api.replacementcount - 1
			var replacement = api.replacements + i

			'' Does the construct match this replacement pattern?
			if constructlen = replacement->patternlen then
				if tkCTokenRangesAreEqual(x, patternbegin, constructlen) then
					'' Remove the construct
					var location = tkGetLocation(x)
					tkRemove(x, nxt - 1)

					'' The token(s) we insert must have a source location so we can
					'' check which .h file it belongs to later: giving it
					'' the location of the construct's first token.

					if replacement->tofb then
						'' Insert TK_FBCODE instead
						tkInsert(x, TK_FBCODE, replacement->tocode)
						tkSetLocation(x, location)
						nxt = x + 1
					else
						'' Insert C tokens instead
						nxt = lexLoadC(x, replacement->tocode, sourceinfoForZstring("C code from replacements file"))

						'' Remove EOLs, as done by the CPP
						scope
							var i = x
							while i < nxt

								if tkGet(i) = TK_EOL then
									tkRemove(i, i)
									i -= 1
									nxt -= 1
								end if

								i += 1
							wend
						end scope

						'' If it looks like we inserted a #directive, add an EOL at the end,
						'' and add the proper tk flags
						if tkGet(x) = TK_HASH then
							tkAddFlags(x, x, TKFLAG_STARTOFDIRECTIVE)
							tkInsert(nxt, TK_EOL)
							tkAddFlags(x, nxt, TKFLAG_DIRECTIVE)
							nxt += 1
						end if

						for i as integer = x to nxt - 1
							tkSetLocation(i, location)
						next
					end if

					exit for
				end if
			end if

			patternbegin += replacement->patternlen
		next

		x = nxt
	wend

	'' Remove patterns from the end of the tk buffer again
	tkRemove(0, xmainbegin - 1)
end sub