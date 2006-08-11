package PAR::Repository::ScanPAR;

use 5.006;
use strict;
use warnings;

use Carp qw/croak/;
use File::Spec::Functions qw/catfile splitpath catdir/;
use File::Path qw/rmtree/;
use ExtUtils::Manifest;
require ExtUtils::MM;

our $VERSION = '0.03';

=head1 NAME

PAR::Repository::ScanPAR - Scan a PAR distro for packages and scripts

=head1 SYNOPSIS

  use PAR::Repository;
  ...
  my $pkgs    = $repository->scan_par_for_packages;
  my $scripts = $repository->scan_par_for_scripts;

=head1 DESCRIPTION

This module is for internal use only.
It contains code for scanning a PAR distribution for
packages and scripts.

=head2 EXPORT

None.

=head1 METHODS

Following is a list of class and instance methods.
(Instance methods until otherwise mentioned.)

There is no C<PAR::Repository::ScanPAR> object.
L<PAR::Repository> inherits from this class.

=cut

=head2 scan_par_for_packages

First argument must be the path and file name of a PAR
distribution. Scans that distribution for .pm files and scans
those for packages and versions. Returns a hash of
the package names as keys and hash refs as values. The hashes contain
the path to the file in the PAR as the key "file" and (if found)
the version of the package is the key "version".

Returns undef on error.

=cut

sub scan_par_for_packages {
	my $self = shift;
	$self->verbose(2, "Entering scan_par_for_packages()");
	my $par = shift;
	
	my $old_path = Cwd::cwd();

	my (undef, $tmpdir) = $self->_unzip_dist_to_tmpdir($par);
	chdir($tmpdir);
	my @pmfiles = grep { /\.pm$/i } keys %{ExtUtils::Manifest::manifind()};
	
	my %pkg;
	foreach my $pmfile (@pmfiles) {
		my $hash = $self->_parse_packages_from_pm($pmfile);
		next if not defined $hash;
		foreach (keys %$hash) {
			$pkg{$_} = $hash->{$_}
			  if not defined $pkg{$_}{version}
			     or (defined $hash->{$_}{version}
					 and $pkg{$_}{version} < $hash->{$_}{version});
		}
	}
	
	chdir($old_path);
	rmtree([$tmpdir]);
	return \%pkg;
}


sub _parse_packages_from_pm {
	my $self = shift;
	$self->verbose(2, "Entering _parse_packages_from_pm()");
	my $file = shift;
	my %pkg;
	open my $fh, '<', $file or return undef;


	# stealing from PAUSE indexer.
	local $/ = "\n";
	my $inpod = 0;
      PLINE: while (<$fh>) {
            chomp;
            my($pline) = $_;
            $inpod = $pline =~ /^=(?!cut)/ ? 1 :
                $pline =~ /^=cut/ ? 0 : $inpod;
            next if $inpod;
            next if substr($pline,0,4) eq "=cut";

            $pline =~ s/\#.*//;
            next if $pline =~ /^\s*$/;
            last PLINE if $pline =~ /\b__(END|DATA)__\b/;

            my $pkg;

            if (
                $pline =~ m{
                         (.*)
                         \bpackage\s+
                         ([\w\:\']+)
                         \s*
                         ( $ | [\}\;] )
                        }x) {
                $pkg = $2;

            }

            if ($pkg) {
                # Found something

                # from package
                $pkg =~ s/\'/::/;
                next PLINE unless $pkg =~ /^[A-Za-z]/;
                next PLINE unless $pkg =~ /\w$/;
                next PLINE if $pkg eq "main";
				#next PLINE if length($pkg) > 64; #64 database
                #restriction
                $pkg{$pkg}{file} = $file;
				my $version = MM->parse_version($file);
				$pkg{$pkg}{version} = $version if defined $version;
            }
        }

	
	close $fh;
	return \%pkg;
}


=head2 scan_par_for_scripts

First argument must be the path and file name of a PAR
distribution. Scans that distribution for executable files
and scans
those for versions. Returns a hash of
the script names as keys and hash refs as values. The hashes contain
the path to the file in the PAR as the key "file" and (if found)
the version of the script as the key "version".

Returns undef on error.

=cut

sub scan_par_for_scripts {
	my $self = shift;
	$self->verbose(2, "Entering scan_par_for_scripts()");
	my $par = shift;
	
	my $old_path = Cwd::cwd();

	my (undef, $tmpdir) = $self->_unzip_dist_to_tmpdir($par);
	chdir($tmpdir);
	my @scripts =
        grep { /^script\/(?!\.)/i or /^bin\/(?!\.)/i }
        keys %{ExtUtils::Manifest::manifind()};
	
	my %scr;
	foreach my $script (@scripts) {
        (undef, undef, my $scriptname) = splitpath($script);
        
        my $version = MM->parse_version($script);
	    $scr{$scriptname} = {
            file => $script,
            version => $version,
        } if not defined $scr{$scriptname}{version}
		    or (defined $version
				and $scr{$scriptname}{version} < $version);
	}
	
	chdir($old_path);
	rmtree([$tmpdir]);
	return \%scr;
}


1;
__END__

=head1 AUTHOR

Steffen Müller, E<lt>smueller@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Steffen Müller

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.6 or,
at your option, any later version of Perl 5 you may have available.

=cut
