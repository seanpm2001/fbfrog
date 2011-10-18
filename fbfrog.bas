#include once "fbfrog.bi"

dim shared as FrogStuff frog

private sub frog_init()
	frog.follow = FALSE
	frog.verbose = FALSE

	list_init(@frog.files, sizeof(FrogFile))
	hash_init(@frog.filehash, 6)

	frog.f = NULL
end sub

private function find_and_normalize _
	( _
		byref origname as string, _
		byval search_paths as integer _
	) as string

	dim as string hardname

	if (search_paths) then
		'' Try to find the include file in one of the parent
		'' directories of the current file.
		'' (Usually the #include will refer to a file in the same
		'' directory or in a sub-directory at the same level or some
		'' levels up)

		ASSUMING(frog.f)
		dim as string parent = path_only(*frog.f->hardname)
		while (len(parent) > 0)
			hardname = parent + origname
			if (file_exists(hardname)) then
				if (frog.verbose) then
					print "  found: " & origname & ": " & hardname
				end if
				exit while
			end if

			if (frog.verbose) then
				print "  not found: " & origname & ": " & hardname
			end if

			parent = path_strip_last_component(parent)
		wend
	end if

	if (len(hardname) = 0) then
		'' Not found; handle it like input files from command line
		hardname = path_make_absolute(origname)
		if (frog.verbose) then
			print "  default: " & origname & ": " & hardname
		end if
	end if

	return path_normalize(hardname)
end function

function frog_add_file _
	( _
		byref origname as string, _
		byval search_paths as integer _
	) as FrogFile ptr

	dim as string hardname = find_and_normalize(origname, search_paths)

	dim as integer length = len(hardname)
	ASSUMING(length > 0)
	dim as zstring ptr s = strptr(hardname)
	dim as uinteger hash = hash_hash(s, length)
	dim as HashItem ptr item = _
			hash_lookup(@frog.filehash, s, length, hash)

	if (item->s) then
		if (frog.verbose) then
			print "  old news: " & origname & ": " & hardname
		end if

		'' Already exists
		return cptr(FrogFile ptr, item->data)
	end if

	if (frog.verbose) then
		print "  found new: " & origname & ": " & hardname
	end if

	'' Add file
	dim as FrogFile ptr f = list_append(@frog.files)
	f->softname = str_duplicate(strptr(origname), len(origname))
	f->hardname = str_duplicate(s, length)
	f->refcount = 0

	'' Add to hash table
	item->s = f->hardname
	item->length = length
	item->hash = hash
	item->data = f
	frog.filehash.count += 1

	return f
end function

private sub print_help()
	print _
	!"usage: fbfrog [-[-]options] *.h\n" & _
	!"For every given C header (*.h) an FB header (*.bi) will be generated.\n" & _
	!"The resulting .bi files may need further editing; watch out for TODOs.\n" & _
	!"options:\n" & _
	!"  --follow      Also translate all #includes that can be found\n" & _
	!"  --verbose     Show more stats and information\n" & _
	 "  --help, --version  Help and version output"

	end 0
end sub

private sub print_version()
	print "0.1"
	end 0
end sub

''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''

	frog_init()

	if (__FB_ARGC__ = 1) then
		print_help()
	end if

	dim as string arg
	for i as integer = 1 to (__FB_ARGC__ - 1)
		arg = *__FB_ARGV__[i]

		if (len(arg) = 0) then
			continue for
		end if

		if (arg[0] <> asc("-")) then
			continue for
		end if

		do
			arg = right(arg, len(arg) - 1)
		loop while (left(arg, 1) = "-")

		select case (arg)
		case "follow"
			frog.follow = TRUE

		case "help"
			print_help()

		case "verbose"
			frog.verbose = TRUE

		case "version"
			print_version()

		case else
			if (len(arg) > 0) then
				oops("unknown option: '" & arg & "', try --help")
			end if

		end select
	next

	'' Now that all options are known -- start adding the files
	for i as integer = 1 to (__FB_ARGC__ - 1)
		arg = *__FB_ARGV__[i]
		if (arg[0] <> asc("-")) then
			frog_add_file(arg, FALSE, FALSE)
		end if
	next

	''
	'' Preparse everything to collect a list of all involved headers.
	'' (no translation yet)
	''
	'' Data collected by the preparse:
	'' - All modes except the default want to know more input files
	''   from #includes, including /their/ #includes, and so on...
	''
	if (frog.follow) then
		'' Go through all input files, and new ones as they are
		'' appended to the list...
		frog.f = list_head(@frog.files)
		while (frog.f)
			print "preparsing: " & *frog.f->softname

			tk_init()
			lex_insert_file(0, *frog.f->hardname)

			preparse_toplevel()

			tk_end()

			frog.f = list_next(frog.f)
		wend
	end if

	''
	'' By default, all input files are translated 1:1.
	''
	'' --follow only enables the preparse, to find more input files.
	''

	''
	'' Regular translation, 1:1
	''
	frog.f = list_head(@frog.files)
	while (frog.f)
		print "translating: " & *frog.f->softname

		tk_init()
		lex_insert_file(0, *frog.f->hardname)

		parse_toplevel(0)
		translate_toplevel()

		emit_write_file(path_strip_ext(*frog.f->hardname) & ".bi")
		tk_end()

		frog.f = list_next(frog.f)
	wend

	print "done: ";
	emit_stats()
	if (frog.verbose) then
		print "  file hash: ";
		hash_stats(@frog.filehash)
		lex_stats()
	end if
	end 0
