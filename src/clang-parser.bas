#include once "clang-parser.bi"
#include once "util-str.bi"

constructor ClangParser()
	index = clang_createIndex(0, 0)
end constructor

destructor ClangParser()
	clang_disposeTranslationUnit(unit)
	clang_disposeIndex(index)
end destructor

sub ClangParser.addArg(byval arg as const zstring ptr)
	args.append(strDuplicate(arg))
end sub

sub ClangParser.parseTranslationUnit()
	print "libclang invocation args:";
	for i as integer = 0 to args.count - 1
		print " ";*args.p[i];
	next
	print

	dim e as CXErrorCode = _
		clang_parseTranslationUnit2(index, _
			NULL, args.p, args.count, _
			NULL, 0, _
			CXTranslationUnit_Incomplete, _
			@unit)
	if e <> CXError_Success then
		oops("libclang parsing failed with error code " & e)
	end if
end sub