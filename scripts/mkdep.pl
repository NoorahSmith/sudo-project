#!/usr/bin/env perl
#
# SPDX-License-Identifier: ISC
#
# Copyright (c) 2011-2021 Todd C. Miller <Todd.Miller@sudo.ws>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

use File::Temp qw/ :mktemp  /;
use Fcntl;
use warnings;

die "usage: $0 [--builddir=dir] [--srcdir=dir] Makefile.in ...\n" unless $#ARGV >= 0;

my @incpaths;
my %dir_vars;
my %implicit;
my %generated;
my $top_builddir = ".";
my $top_srcdir;

# Check for srcdir and/or builddir, if present
while ($ARGV[0] =~ /^--(src|build)dir=(.*)/) {
    if ($1 eq 'src') {
	$top_srcdir = $2;
    } else {
	$top_builddir = $2;
    }
    shift @ARGV;
}
chdir($top_srcdir) if defined($top_srcdir);

# Read in MANIFEST or fail if not present
my %manifest;
die "unable to open MANIFEST: $!\n" unless open(MANIFEST, "<MANIFEST");
while (<MANIFEST>) {
    chomp;
    next unless /([^\/]+\.[cly])$/;
    $manifest{$1} = $_;
}

foreach (@ARGV) {
    mkdep($_);
}

sub fmt_depend {
    my ($obj, $src) = @_;
    my $ret;

    my $deps = sprintf("%s: %s %s", $obj, $src,
	join(' ', find_depends($src)));
    if (length($deps) > 80) {
	my $off = 0;
	my $indent = length($obj) + 2;
	while (length($deps) - $off > 80 - $indent) {
	    my $pos;
	    if ($off != 0) {
		$ret .= ' ' x $indent;
		$pos = rindex($deps, ' ', $off + 80 - $indent - 2);
	    } else {
		$pos = rindex($deps, ' ', $off + 78);
	    }
	    $ret .= substr($deps, $off, $pos - $off) . " \\\n";
	    $off = $pos + 1;
	}
	$ret .= ' ' x $indent;
	$ret .= substr($deps, $off) . "\n";
    } else {
	$ret = "$deps\n";
    }

    $ret;
}

sub mkdep {
    my $file = $_[0];
    $file =~ s:^\./+::;		# strip off leading ./
    $file =~ m:^(.*)/[^/]+$:;
    my $srcdir = $1;		# parent dir of Makefile

    my $makefile;
    if (open(MF, "<$file")) {
	local $/;		# enable "slurp" mode
	$makefile = <MF>;
    } else {
	warn "$0: $file: $!\n";
	return undef;
    }
    close(MF);

    # New makefile, minus the autogenerated dependencies
    my $separator = "# Autogenerated dependencies, do not modify";
    my $new_makefile = $makefile;
    $new_makefile =~ s/${separator}.*$//s;
    $new_makefile .= "$separator\n";

    # Old makefile, join lines with continuation characters
    $makefile =~ s/\\\n//mg;

    # Expand some configure bits
    $makefile =~ s:\@DEV\@::g;
    $makefile =~ s:\@COMMON_OBJS\@:aix.lo event_poll.lo event_select.lo:;
    $makefile =~ s:\@SUDO_OBJS\@:intercept.pb-c.o openbsd.o preload.o selinux.o sesh.o solaris.o:;
    $makefile =~ s:\@SUDOERS_OBJS\@:bsm_audit.lo linux_audit.lo ldap.lo ldap_util.lo ldap_conf.lo solaris_audit.lo sssd.lo:;
    # XXX - fill in AUTH_OBJS from contents of the auth dir instead
    $makefile =~ s:\@AUTH_OBJS\@:afs.lo aix_auth.lo bsdauth.lo dce.lo fwtk.lo getspwuid.lo kerb5.lo pam.lo passwd.lo rfc1938.lo secureware.lo securid5.lo sia.lo:;
    $makefile =~ s:\@DIGEST\@:digest.lo digest_openssl.lo digest_gcrypt.lo:;
    $makefile =~ s:\@LTLIBOBJS\@:arc4random.lo arc4random_buf.lo arc4random_uniform.lo cfmakeraw.lo closefrom.lo dup3.lo explicit_bzero.lo fchmodat.lo freezero.lo fstatat.lo fnmatch.lo getaddrinfo.lo getcwd.lo getentropy.lo getgrouplist.lo getdelim.lo getopt_long.lo getusershell.lo glob.lo gmtime_r.lo inet_ntop_lo inet_pton.lo isblank.lo localtime_r.lo memrchr.lo mksiglist.lo mksigname.lo mktemp.lo nanosleep.lo openat.lo pipe2.lo pread.lo pwrite.lo pw_dup.lo reallocarray.lo sha2.lo sig2str.lo siglist.lo signame.lo snprintf.lo str2sig.lo strlcat.lo strlcpy.lo strndup.lo strnlen.lo strsignal.lo unlinkat.lo utimens.lo:;

    # Parse OBJS lines
    my %objs;
    while ($makefile =~ /^[A-Z0-9_]*OBJS\s*=\s*(.*)/mg) {
	foreach (split/\s+/, $1) {
	    next if /^\$[\(\{].*[\)\}]$/; # skip included vars for now
	    $objs{$_} = 1;
	}
    }

    # Find include paths
    @incpaths = ();
    while ($makefile =~ /-I(\S+)/mg) {
	push(@incpaths, $1) unless $1 eq ".";
    }

    # Check for generated files
    if ($makefile =~ /GENERATED\s*=\s*(.+)$/m) {
	foreach (split(/\s+/, $1)) {
	    $generated{$_} = 1;
	}
    }

    # Values of srcdir, top_srcdir, top_builddir, incdir
    %dir_vars = ();
    $file =~ m:^(.*)/+[^/]+:;
    $dir_vars{'srcdir'} = $1 || '.';
    $dir_vars{'devdir'} = $dir_vars{'srcdir'};
    $dir_vars{'authdir'} = $dir_vars{'srcdir'} . "/auth";
    $dir_vars{'builddir'} = $top_builddir . "/" . $dir_vars{'srcdir'};
    $dir_vars{'top_srcdir'} = $top_srcdir;
    $dir_vars{'sudoers_srcdir'} = $top_srcdir . "/plugins/sudoers";
    #$dir_vars{'top_builddir'} = '.';
    $dir_vars{'incdir'} = 'include';

    # Find implicit rules for generated .o and .lo files
    %implicit = ();
    while ($makefile =~ /^\.[ci]\.(l?o|i|plog):\s*\n\t+(.*)$/mg) {
	$implicit{$1} = $2;
    }

    # Find existing .o and .lo dependencies
    my %old_deps;
    while ($makefile =~ /^(\w+\.l?o):\s*(\S+\.c)/mg) {
	$old_deps{$1} = $2;
    }

    # Check whether static objs are disabled for .lo files
    my $disable_static;
    if ($makefile =~ /LTFLAGS\s*=\s*(.+)$/m) {
	my $ltflags = $1;
	$_ = $implicit{"lo"};
	if (defined($_)) {
	    s/\$[\(\{]LTFLAGS[\)\}]/$ltflags/;
	    $disable_static = /--tag=disable-static/;
	}
    }

    # Sort files so we do .lo files first
    foreach my $obj (sort keys %objs) {
	next unless $obj =~ /(\S+)\.(l?o)$/;
	if (!$disable_static && $2 eq "o" && exists($objs{"$1.lo"})) {
	    # We have both .lo and .o files, only the .lo should be used
	    warn "$file: $obj should be $1.lo\n";
	} else {
	    # Use old dependencies when mapping objects to their source.
	    # If no old dependency, use the MANIFEST file to find the source.
	    my $base = $1;
	    my $ext = $2;
	    my $src = $base . '.c';
	    if (exists $old_deps{$obj}) {
		$src = $old_deps{$obj};
	    } elsif (exists $manifest{$src}) {
		$src = $manifest{$src};
		foreach (sort { length($b) <=> length($a) } keys %dir_vars) {
		    next if $_ eq "devdir";
		    last if $src =~ s:^\Q$dir_vars{$_}/\E:\$\($_\)/:;
		}
	    } else {
		warn "$file: unable to find source for $obj ($src) in MANIFEST\n";
		if (-f "$srcdir/$src") {
		    $src = '$(srcdir)/' . $src;
		}
	    }
	    my $imp = $implicit{$ext};
	    $imp =~ s/\$</$src/g;

	    my $deps = fmt_depend($obj, $src);
	    $new_makefile .= $deps;
	    $new_makefile .= "\t$imp\n";

	    # PVS Studio files (.i and .plog) but only do them once.
	    if ($ext ne "o" || !exists($objs{"$base.lo"})) {
		$imp = $implicit{"i"};
		if (exists $implicit{"i"} && exists $implicit{"plog"}) {
		    $imp = $implicit{"i"};
		    $deps =~ s/\.l?o/.i/;
		    $new_makefile .= $deps;
		    $new_makefile .= "\t$imp\n";

		    $imp = $implicit{"plog"};
		    $imp =~ s/ifile=\$<; *//;
		    $imp =~ s/\$\$\{ifile\%i\}c/$src/;
		    $obj =~ /(.*)\.[a-z]+$/;
		    $new_makefile .= "${1}.plog: ${1}.i\n";
		    $new_makefile .= "\t$imp\n";
		}
	    }
	}
    }

    my $newfile = $file . ".new";
    if (!open(MF, ">$newfile")) {
	warn("cannot open $newfile: $!\n");
    } else {
	print MF $new_makefile || warn("cannot write $newfile: $!\n");
	close(MF) || warn("cannot close $newfile: $!\n");;
	rename($newfile, $file);
    }
}

exit(0);

sub find_depends {
    my $src = $_[0];
    my ($deps, $code, %headers);

    if ($src !~ /\//) {
	# generated file, local to build dir
	$src = "$dir_vars{'builddir'}/$src";
    }

    # resolve $(srcdir) etc.
    foreach (keys %dir_vars) {
	$src =~ s/\$[\(\{]$_[\)\}]/$dir_vars{$_}/g;
    }

    # find open source file and find headers used by it
    if (!open(FILE, "<$src")) {
	warn "unable to open $src\n";
	return "";
    }
    local $/;		# enable "slurp" mode
    $code = <FILE>;
    close(FILE);

    # find all headers
    while ($code =~ /^\s*#\s*include\s+["<](\S+)[">]/mg) {
	my ($hdr, $hdr_path) = find_header($src, $1);
	if (defined($hdr)) {
	    $headers{$hdr} = 1;
	    # Look for other includes in the .h file
	    foreach (find_depends($hdr_path)) {
		$headers{$_} = 1;
	    }
	}
    }

    sort keys %headers;
}

# find the path to a header file
# returns path or undef if not found
sub find_header {
    my $src = $_[0];
    my $hdr = $_[1];

    # Look for .h.in files in top_builddir and build dir
    return ("\$(top_builddir\)/$hdr", "./${hdr}.in") if -r "./${hdr}.in";
    return ("./$hdr", "$dir_vars{'srcdir'}/${hdr}.in") if -r "$dir_vars{'srcdir'}/${hdr}.in";

    if (exists $generated{$hdr}) {
	my $hdr_path = $dir_vars{'devdir'} . '/' . $hdr;
	return ('$(devdir)/' . $hdr, $hdr_path) if -r $hdr_path;
    }
    foreach my $inc (@incpaths) {
	my $hdr_path = "$inc/$hdr";
	# resolve variables in include path
	foreach (keys %dir_vars) {
	    next if $_ eq "devdir";
	    $hdr_path =~ s/\$[\(\{]$_[\)\}]/$dir_vars{$_}/g;
	}
	return ("$inc/$hdr", $hdr_path) if -r $hdr_path;
    }
    # Check path relative to src dir (XXX - should be for "include" only)
    if ($src =~ m#^(.*)/[^/]+$# && -r "$1/$hdr") {
	my $hdr_path = "$1/$hdr";
	$hdr_path =~ s#/[^/]+/\.\.##g;	# resolve ..
	my $hdr_pretty = $hdr_path;
	foreach (sort { length($dir_vars{$b}) <=> length($dir_vars{$a}) } keys %dir_vars) {
	    next if $_ eq "devdir";
	    $hdr_pretty =~ s/$dir_vars{$_}/\$($_)/;
	}
	return ($hdr_pretty, $hdr_path);
    }

    undef;
}
