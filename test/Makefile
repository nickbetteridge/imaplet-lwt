sync: sync.ml
	ocamlbuild -pkgs lwt,lwt.syntax,lwt.unix,irmin.unix sync.native

dedup: dedup.ml
	ocamlbuild -pkgs imaplet,imaplet.commands,imaplet.parsemail,lwt,lwt.syntax,lwt.unix dedup.native

maildir_read: maildir_read.ml
	ocamlbuild -pkgs lwt,lwt.unix,lwt.syntax,re,re.posix,irmin.unix,imaplet,imaplet.commands maildir_read.native

irvsfsio: irvsfsio.ml
	ocamlbuild -pkgs lwt,lwt.syntax,lwt.unix,re,re.posix,irmin.unix,zip irvsfsio.native