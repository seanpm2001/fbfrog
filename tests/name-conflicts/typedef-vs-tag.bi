#pragma once

'' The following symbols have been renamed:
''     variable x1_ alias "x1"
''     variable x2_ alias "x2"

type myint as long
type UDT2 as long

type UDT
	f as single
end type

type UDT3
	f as single
end type

dim shared x1 as myint
dim shared x1_ as UDT2
dim shared x2 as UDT
dim shared x2_ as UDT3
