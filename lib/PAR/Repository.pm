package PAR::Repository;

use 5.006;
use strict;
use warnings;

use Carp qw/croak/;
use File::Spec::Functions qw/catfile catdir splitpath/;
use File::Path qw/mkpath/;
use PAR::Dist qw//;
use YAML::Syck qw//;
use File::Copy qw//;
use Cwd qw//;
use Archive::Zip qw//;
use File::Temp qw//;
use version qw//;

use base qw/
    PAR::Repository::Zip
    PAR::Repository::DBM
    PAR::Repository::ScanPAR
    PAR::Repository::Query
/;

use constant REPOSITORY_INFO_FILE => 'repository_info.yml';

our $VERSION = '0.14';
our $VERBOSE = 0;

# template for a repository_info.yml file
our $Info_Template = {
    repository_version => $VERSION,
};

# Hash of compatible PAR::Repository versions
our $Compatible_Versions = {
    $VERSION => 1,
    '0.13' => 1,
    '0.12' => 1,
    '0.11' => 1,
    '0.10' => 1,
    '0.03' => 1,
    '0.02' => 1,
};

=head1 NAME

PAR::Repository - Create and modify PAR repositories

=head1 SYNOPSIS

  # Usually, you want to use the 'parrepo' script which comes with
  # this distribution.
  use PAR::Repository;
  
  my $repo = PAR::Repository->new( path => '/path/to/repository' );
  # creates a new repository if it doesn't exist, opens it if it
  # does exist.
  
  $repo->inject(
    file => 'Foo-Bar-0.01-x86_64-linux-gnu-thread-multi-5.8.7.par'
  );
  $repo->remove(
    file => '...'
  );
  $repo->query_module(regex => 'Foo::Bar');

=head1 DESCRIPTION

This module is intended for creation and maintenance of PAR repositories.
A PAR repository is collection of F<.par> archives which contain Perl code
and associated libraries for use on specific platforms. In the most common
case, these archives differ from CPAN distributions in that they ship the
(possibly compiled) output of C<make> in the F<blib/> subdirectory of the
CPAN distribution's build directory.

You can access a PAR repository using the L<PAR::Repository::Client> module
or the L<PAR> module which provides syntactic sugar around the client.
L<PAR> allows you to load libraries from repositories on demand.

=head2 PAR REPOSITORIES

A PAR repository is, basically, just a directory with certain stuff in it.
It contains:

=over 2

=item modules_dists.dbm.zip

An index that maps module names to file names.
Details can be found in L<PAR::Repository::DBM>.

=item symlinks.dbm.zip

An index that maps file names to other files. You shouldn't have to care
about it.
Details can be found in L<PAR::Repository::DBM>.

=item scripts_dists.dbm.zip

An index that maps script names to file names.
Details can be found in L<PAR::Repository::DBM>.

=item repository_info.yml

A simple YAML file which contains meta information for the repository.
It currently contains the following bits of information:

=over 2

=item repository_version

The version of PAR::Repository this repository was created with.
When opening an existing repository, PAR::Repository checks that the
repository was created by a compatible PAR::Repository version.

Similarily, PAR::Repository::Client checks that the repository has
a compatible version.

=back

=item I<arch/perl-version> directories

Your system architecture is identified with a certain string.
For example, my development box is C<x86_64-linux-gnu-thread-multi>.
For every such architecture for which there are PAR archives
in the repository, there is a directory with the name of the
architecture.

There is one special directory called C<any_arch> which is meant
for PAR archives that are architecture independent. (Usually
I<pure-perl> modules.)

In every such architecture directory, there is a number of directories
for every Perl version. (5.6.0, 5.6.1, 5.8.0, ...)
Again, there is a special directory for modules
that work with any version of Perl.
This directory is called C<any_version>.

Of course, a module won't run with Perl 4 and probably not even with
5.001. Whether a module works with I<any version> of perl is something
you need to decide when injecting modules into the repository and depends
on the scope of the repository.

These inner directories contain the PAR archives. The directories exist
mostly because large repositories with a lot of modules for a lot of
architectures would otherwise have too large directory lists.

=item PAR archives

Within the I<arch/perl-version> directories come the actual PAR archives.
The name of each such file is of the following form:

I<Distribution-Name>-I<Distribution-Version>-I<Architecture>-I<Perl-Version>.par

=back

=head1 METHODS

Following is a list of class and instance methods.
(Instance methods until otherwise mentioned.)

Other methods callable on C<PAR::Repository> objects are inherited
from classes listed in the I<SEE ALSO> section.

=cut

=head2 new

Creates a new PAR::Repository object. Takes named arguments. 

Mandatory paramater:

C<path> should be the path to the
PAR repository. If the repository does not exist yet, it
is created empty. If the repository exists, it is I<opened>.
That means any modifications you apply to the repository object
are applied to the I<opened> repository on disk.

=cut

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;

	croak(__PACKAGE__."->new() takes an even number of arguments.")
	  if @_ % 2;
	my %args = @_;
	
	croak(__PACKAGE__."->new() needs a 'path' argument.")
	  if not defined $args{path};
	
	my $path = $args{path};
	my $self = bless {
		path => $path,
        
        # The tied dbm hashes
		modules_hash => undef,
		symlinks_hash => undef,
		scripts_hash => undef,

        # The temp dbm files on disk
		modules_dbm_temp_file => undef,
		symlinks_dbm_temp_file => undef,
		scripts_dbm_temp_file => undef,
       
        # The YAML info as Perl data structure
        info => undef,
	} => $class;

	$self->verbose(2, "Created new repository object in path '$path'");
	
	# check that the repository exists or create it.	
	my $mod_dbm = catfile($path, PAR::Repository::DBM::MODULES_DBM_FILE());
	my $sym_dbm = catfile($path, PAR::Repository::DBM::SYMLINKS_DBM_FILE());
	my $scr_dbm = catfile($path, PAR::Repository::DBM::SCRIPTS_DBM_FILE());
	my $info_file = catfile($path, PAR::Repository::REPOSITORY_INFO_FILE());
	if (
        -d $path
        and -f $mod_dbm.'.zip' and -f $sym_dbm.'.zip'
        and -f $info_file
    ) {
		# everything is in place. good.
		$self->verbose(3, "Repository exists");

        # load repository info
        $self->{info} = YAML::Syck::LoadFile($info_file);
        if (
            not defined $self->{info}
            or not exists $self->{info}{repository_version}
        ) {
            croak("Repository exists, but it does not contain a valid repository_info.yml file.");
        }
        elsif (
            not exists
            $Compatible_Versions->{$self->{info}{repository_version}}
        ) {
            croak("Repository exists, but it was created with an incompatible version of PAR::Repository (".$self->{info}{repository_version}.")");
        }
        # the following is a special case because the "incompatible changes
        # with every "\d+.\d" release" rule was introduced in 0.10
        elsif (
            $Compatible_Versions->{$self->{info}{repository_version}} eq '0.03'
        ) {
            $self->_update_info_version or return ();
            $self->verbose(3, "Updated repository version");
            $self->verbose(3, "Opened repository successfully");
        }
        else {
            $self->verbose(3, "Opened repository successfully");
        }
        
        # Generate scripts db and upgrade repository version
        # if the scripts db doesn't exist.
        if (not -f $scr_dbm.'.zip') {
		    $self->verbose(1, "Upgrading repository version to $VERSION");
            $self->_update_info_version or return ();
		    $self->verbose(3, "Creating scripts database");
    		my ($vol, $path, $file) = splitpath($scr_dbm);
	    	$self->_zip_file($scr_dbm, $scr_dbm.'.zip', $file);
    		unlink($scr_dbm);
        }
        
	}
	else {
		# create it.
		$self->verbose(3, "Repository doesn't exist yet");
		if (-d $path) {
			croak("The repository path exists, but is not a repository. Delete it to create a new repository.");
		}
		mkpath([$path]);
		{
			my $mod_db = DBM::Deep->new($mod_dbm);
			my $sym_db = DBM::Deep->new($sym_dbm);
			my $scr_db = DBM::Deep->new($scr_dbm);
		}

		$self->verbose(3, "Creating repository databases");
		my ($vol, $path, $file) = splitpath($mod_dbm);
		$self->_zip_file($mod_dbm, $mod_dbm.'.zip', $file);
		unlink($mod_dbm);
		($vol, $path, $file) = splitpath($sym_dbm);
		$self->_zip_file($sym_dbm, $sym_dbm.'.zip', $file);
		unlink($sym_dbm);
		($vol, $path, $file) = splitpath($scr_dbm);
		$self->_zip_file($scr_dbm, $scr_dbm.'.zip', $file);
		unlink($scr_dbm);

        YAML::Syck::DumpFile($info_file, $Info_Template);
        $self->{info} = YAML::Syck::LoadFile($info_file);
	}
	return $self;
}



=head2 inject

Injects a new PAR distribution into the repository. Takes named parameters.

Mandatory parameters: I<file>, the path and filename of the PAR distribution
to inject. The name of the file can be used to automatically determine the
I<distname>, I<distversion>, I<arch>, and I<perlversion> parameters if the 
form of the file name is as follows:

Dist-Name-0.01-x86_64-linux-gnu-thread-multi-5.8.7.par

This would set C<distname => 'Dist-Name', distversion => '0.01',
arch => 'linux-gnu-thread-multi', perlversion => '5.8.7'>. You can override
this automatic detection using the corresponding parameters.

If the file exists in the repository, inject returns false. If the file
was added successfully, inject returns true. See the C<overwrite> parameter
for details.

C<inject()> scans the distribution for modules and indexes these in
the modules-dists dbm. Additionally, it scans the distribution for
scripts in the C<script> and C<bin> subdirectories of the distribution.
(All files in these folders are considered executables. C<main.pl> is
skipped.) You can turn the indexing of scripts off with the C<no_scripts>
parameter.

Optional parameters:

=over 2

=item I<distname>

The distribution name.

=item I<distversion>

The distribution version.

=item I<arch>

The architecture string. It can be C<any_arch> in order to inject this
distribution as an architecture independent distribution. You can
use the C<any_arch> parameter for this as well (recommended).

Setting this to C<any_arch> is slightly different from using the
parameter of the same name. Setting C<arch=>'any_arch'>
actually puts the file into the C<any_arch> directory. Setting only
the parameter C<any_arch> creates a symlink there.

=item I<perlversion>

The version of perl. Note that it has to be in the C<5.8.7> and not
in the C<5.008007> form!

There is a special case of setting this to C<any_version> meaning
that the distribution can run on any version of perl. The distribution
will then be injected into the C<any_version> tree of the repository.
You can also achieve this by using the C<any_version> parameter which is
recommended.

Setting this to C<any_version> is slightly different from using the
parameter of the same name. Setting C<perlversion=>'any_version'>
actually puts the file into the C<any_version> directory. Setting only
the parameter C<any_version> creates a symlink there.

=item I<any_arch>

Specifies that this distribution is suitable for any architecture.
(Default: no.)

If set, a symlink to the distribution file is created in the
C<any_arch> directory.

=item I<any_version>

Specifies that this distribution is suitable for any version of perl.
(Default: no.)

If set, a symlink to the distribution file is created in the
C<any_version> directory.

=item I<overwrite>

If this is set to a true value, if the file exists in the repository, it
will be overwritten.

=item I<no_scripts>

By default, PAR::Repository indexes all modules found in a distribution
as well as all scripts. Set this parameter to a true value to
skip indexing scripts.

=back

=cut

sub inject {
	my $self = shift;
	croak(__PACKAGE__."->inject() takes an even number of arguments.")
	  if @_ % 2;
	  
	$self->verbose(2, "Entering inject()");
	
	my %args = @_;
	
	my $dfile = $args{file};
	croak(__PACKAGE__."->inject() needs a 'file' parameter.")
	  if not defined $dfile;
	croak(__PACKAGE__."->inject(): Specified file '$dfile' does not exist.")
	  if not -f $dfile;
	
    # determine the name of the target (in-repository) file
	my ($target_file, $distname, $distver, $arch, $perlver)
	  = $self->_get_target_file('inject', \%args);

	$self->verbose(3, "Target file will be '$target_file'");

	# read META.yml from PAR archive
	my $meta = PAR::Dist::get_meta($target_file);
	my $meta_data;
	if (defined $meta) {
		$self->verbose(3, "We have a META.yml");
		$meta_data = YAML::Syck::Load($meta);
	}
	
	my $packages;
	if (defined $meta_data and exists $meta_data->{provides}) {
		# cool, we have a working META.yml with provides!
		$self->verbose(3, "... which has a 'provides' field");
		$packages = $meta_data->{provides};
	}
	else {
		# we need to do the scanning ourselves (damn)
		$self->verbose(3, "Need to scan for .pm files");
		$packages = $self->scan_par_for_packages($dfile);
	}

	if (not defined $packages) {
		# error scanning
		croak("Your PAR distribution is either invalid or doesn't contain any modules.");
	}

    # determine any scripts to index
    my $scripts;
    if (not $args{no_scripts}) {
		$self->verbose(3, "Scanning par for scripts");
        $scripts = $self->scan_par_for_scripts($dfile);
    }

	# create path in repository
	my $destpath = catdir($arch, $perlver);
	$self->verbose(3, "Creating path in repository: '$destpath'");
	mkpath( catdir($self->{path}, $destpath) );

	# copy file over
	my $target_in_rep   =  catfile($destpath, $target_file);
	my $complete_target =  catdir($self->{path}, $target_in_rep);
	if (-f $complete_target) {
		# damn, we're overwriting an existing archive or symlink.
		if (not $args{overwrite}) {
			# don't overwrite
			$self->verbose(1, "Found existing file '$target_in_rep'. Not overwriting because 'overwrite' isn't set.");
			return undef;
		}
		elsif (-l $complete_target) {
			$self->verbose(1, "Found existing symlink '$target_in_rep'. Overwriting because 'overwrite' is set.");
			$self->_remove_symlink(sym => $target_in_rep);
		}
		if ($args{overwrite}) {
			$self->verbose(1, "Found existing file '$target_in_rep'. Overwriting because 'overwrite' is set.");
			$self->remove(file => $target_in_rep);
		}
	}
	File::Copy::copy($dfile, $complete_target);

	# insert into modules dbm.
	$self->verbose(3, "Inserting packages into modules DBM");
	$self->_add_packages(packages => $packages, file => $target_file);

    if (not $args{no_scripts}) {
    	# insert into scripts dbm.
	    $self->verbose(3, "Inserting scripts into scripts DBM");
    	$self->_add_scripts(scripts => $scripts, file => $target_file);
    }

	my $is_any_arch = $args{any_arch} && !($arch eq 'any_arch');
	my $is_any_perl = $args{any_version} && !($arch eq 'any_version');
	
	# add symlinks
	$self->verbose(3, "Adding symlinks to symlinks DBM");
	
	if ($is_any_arch) {
		my $dir = catdir('any_arch', $perlver);
		mkpath(catdir($self->{path}, $dir));
		my $sym = join('-', $distname, $distver, 'any_arch', $perlver).'.par';
		my $success = $self->_add_symlink(
			file => $target_file,
			sym => $sym,
			overwrite => $args{overwrite},
		);
		# associate packages and scripts with symlink as well
		$self->_add_packages(packages => $packages, file => $sym)
		  if $success;
		$self->_add_scripts(scripts => $scripts, file => $sym)
		  if $success and not $args{no_scripts};
	}
	if ($is_any_perl) {
		my $dir = catdir($arch, 'any_version');
		mkpath(catdir($self->{path}, $dir));
		my $sym = join('-', $distname, $distver, $arch, 'any_version').'.par';
		my $success = $self->_add_symlink(
			file => $target_file,
			sym => $sym,
			overwrite => $args{overwrite},
		);
		# associate packages and scripts with symlink as well
		$self->_add_packages(packages => $packages, file => $sym)
		  if $success;
		$self->_add_scripts(scripts => $scripts, file => $sym)
		  if $success and not $args{no_scripts};
	}
	if ($is_any_arch and $is_any_perl) {
		my $dir = catdir('any_arch', 'any_version');
		mkpath(catdir($self->{path}, $dir));
		my $sym = join('-', $distname, $distver, 'any_arch', 'any_version').'.par';
		my $success = $self->_add_symlink(
			file => $target_file,
			sym => $sym,
			overwrite => $args{overwrite},
		);
		# associate packages and scripts with symlink as well
		$self->_add_packages(packages => $packages, file => $sym)
		  if $success;
		$self->_add_scripts(scripts => $scripts, file => $sym)
		  if $success and not $args{no_scripts};
	}

	$self->close_modules_dbm;
	$self->close_symlinks_dbm;
	$self->close_scripts_dbm;
	return 1;
}


=head2 remove

Removes a distribution from the repository.

The information needed for this consists of four pieces:
The distribution name, the distribution version, the
architecture name and the perl version.

This information can be gathered from either a file
name (see the I<file> parameter) or from individual
parameters (see below) or from a mixture of these.
The explicit parameters take precedence before the
file name parsing.

If the specified distribution isn't in the repository,
the method returns false. If the specified distribution
is a symlink to another distribution, the symlink will be
removed, but not the linked distribution. If the
specified distribution is an actual distribution in the
repository that has other symlinks, the distribution as
well as any symlinks are removed.

Returns true on success.

Parameters:

=over 2

=item I<file>

The file name of the
distribution to remove. The file name should not
include any path information. That means you must not
worry about the way it is stored in the repository.

Any paths are stripped and the .par extension is
appended if it's not explicitly specified.
The format must be as with the inject() method.

=item I<distname>

The distribution name.

=item I<distversion>

The distribution version.

=item I<arch>

The architecture string. It can be C<any_arch> or an actual
architecture name. For details, see the discussion in the
manual entry for the C<inject> method.

=item I<perlversion>

The version of perl. Note that it has to be in the C<5.8.7> and not
in the C<5.008007> form!

It can be C<any_version> instead of an actual perl version. For details,
see the discussion in the manual entry for the C<inject> method.

=back

You may omit the C<file> parameter if the full file name can be constructed
from the individual pieces of information.

=cut

sub remove {
	my $self = shift;
	croak(__PACKAGE__."->remove() takes an even number of arguments.")
	  if @_ % 2;
	  
	$self->verbose(2, "Entering remove()");
	
	my %args = @_;
	
#	my $dfile = $args{file};
#	croak(__PACKAGE__."->remove() needs a 'file' parameter.")
#	  if not defined $dfile;
#	croak(__PACKAGE__."->remove(): Specified file '$dfile' does not exist.")
#	  if not -f $dfile;
	
    # determine the name of the target (in-repository) file
	my ($target_file, $distname, $distver, $arch, $perlver)
	  = $self->_get_target_file('remove', \%args);

	$self->verbose(3, "Target file for removal will be '$target_file'");

	# change to repo path
	my $old_dir = Cwd::cwd();
	chdir($self->{path});
	
	my $complete_target = catfile( catdir($arch, $perlver), $target_file );

	if (not -f $complete_target and not -l $complete_target) {
		# not in repo
		$self->verbose(1, "Target file is not in repository");
		chdir($old_dir);
		return ();
	}
	elsif (-l $complete_target) {
		# target is a symlink, remove the link only.
		$self->verbose(1, "Target file is a symlink. Removing the symlink only");
		chdir($old_dir);
	    my ($modh) = $self->modules_dbm;
	    my ($scrh) = $self->scripts_dbm;
        if (
            not $self->_remove_files_from_db($modh, [$target_file])
            or not $self->_remove_files_from_db($scrh, [$target_file])
		    or not $self->_remove_symlink(sym => $target_file)
        ) {
            $self->close_modules_dbm;
            $self->close_scripts_dbm;
            return();
        }
        else {
            $self->close_modules_dbm;
            $self->close_scripts_dbm;
            return 1;
        }
	}

	chdir($old_dir);
	
	# target is a file. remove file and its symlinks.
	
	my ($symh) = $self->symlinks_dbm;
	my ($modh) = $self->modules_dbm;
	my ($scrh) = $self->scripts_dbm;
	
	# find links
	# Why so complicated? Because DBM::Deep has too much magic!
	my $links = $symh->{$target_file};
	if (not defined $links) {
		$links = [];
	}
	else {
		$links = [ map {$_} @$links ];
	}

	my @module_and_links = ($target_file);
	push @module_and_links, @$links;

	# remove mention of the distro and links
    # from modules and scripts dbs (This is slow!)
    $self->_remove_files_from_db($modh, \@module_and_links);
    $self->_remove_files_from_db($scrh, \@module_and_links);
    
	# remove links
	foreach my $link (@$links) {
		$self->_remove_symlink(sym => $link)
	}
	
	# remove the whole archive from the symlinks db
	if ( defined($symh->{$target_file}) and @{$symh->{$target_file}} == 0 ) {
		delete $symh->{$target_file};
	}

	# remove file
	$old_dir = Cwd::cwd();
	chdir($self->{path});
	unlink($complete_target)
	  or die "Could not remove file '$complete_target' from repository. Current path is '".Cwd::cwd()."'";
	
	chdir($old_dir);
    $self->close_modules_dbm;
    $self->close_symlinks_dbm;
    $self->close_scripts_dbm;

	return 1;	
}

=head2 verbose

Print a verbose status message. First argument should be an integer,
second argument should be the message.
If the global variable C<$PAR::Repository::VERBOSE> is set to
a value equal to or higher than the integer passed as first argument,
the verbose message will be sent to STDOUT.

The global verbose variable defaults to 0. Setting it to a negative
value should suppress B<any> output except fatal errors.

Valid values are:

  0 => Non-fatal errors.
  1 => Short status messages.
  2 => Method entry messages.-
  3 => Full debug output.

A newline is attached to all output. If the verbosity global
variable is set to a "4", all status messages are sent to
STDERR instead via warn. That means the source line of the
status message is attached.

=cut

sub verbose {
	my $self = shift;
	my $verbosity = shift;
	my $msg = shift;

	if ($PAR::Repository::VERBOSE >= 4) {
		my %call_info;
		@call_info{
			qw(pack file line sub has_args wantarray evaltext is_require)
		} = caller(0);
  		warn "$msg at $call_info{file} line $call_info{line}\n";
	}
	elsif ($PAR::Repository::VERBOSE >= $verbosity) {
		print "$msg\n";
	}
	return;
}

=head2 _cmp_dist_versions

Compares the versions of two files. Takes
two file names as arguments. Parses the distribution
version from those file names and compares those
versions.

Returns -1 if the version of the first file is less than that
of the second file.

Returns 0 if the versions are equal.

Returns 1 if the version of the first file is greater than that
of the second file.

For internal use only.

=cut

sub _cmp_dist_versions {
	my $self = shift;
	my $f1 = shift;
	my $f2 = shift;

	(undef, my $dv1, undef, undef) = PAR::Dist::parse_dist_name($f1);
	(undef, my $dv2, undef, undef) = PAR::Dist::parse_dist_name($f2);

	if (not defined $dv1) {
		return 0 if not defined $dv2;
		return 1;
	}
	elsif (not defined $dv2) {
		return -1;
	}

	my $v1 = version->new($dv1);
	my $v2 = version->new($dv2);
	return($v1 <=> $v2);
}


=head2 _add_packages

Adds a number of package E<lt>-E<gt> file associations to the
modulesE<lt>-E<gt>dists DBM file.

Parameters: C<packages => \%pkg_hash> a hash of package names as keys
and their versions (optionally) as values. C<file => $target_file>
the file in the repository to associate these packages with.

For internal use only!

=cut

sub _add_packages {
	my $self = shift;
	$self->verbose(2, "Entering _add_packages()");
	my %args = @_;
	my $packages = $args{packages};
	my $target_file = $args{file};
	
	my ($hash, $temp_file) = $self->modules_dbm;
	foreach my $pkg (keys %$packages) {
		$hash->{$pkg} = {} if not exists $hash->{$pkg};
		$hash->{$pkg}{$target_file} = $packages->{$pkg}{version};
	}
	return 1;
}

=head2 _add_scripts

Adds a number of script E<lt>-E<gt> file associations to the
scriptsE<lt>-E<gt>dists DBM file.

Parameters: C<scripts => \%script_hash> a hash of script names as keys
and their versions (optionally) as values. C<file => $target_file>
the file in the repository to associate these scripts with.

For internal use only!

=cut

sub _add_scripts {
	my $self = shift;
	$self->verbose(2, "Entering _add_scripts()");
	my %args = @_;
	my $scripts = $args{scripts};
	my $target_file = $args{file};
	
	my ($hash) = $self->scripts_dbm;
	foreach my $scr (keys %$scripts) {
		$hash->{$scr} = {} if not exists $hash->{$scr};
		$hash->{$scr}{$target_file} = $scripts->{$scr}{version};
	}
	return 1;
}


=head2 _add_symlink

Adds a symlink to the repository.
Parameters: C<file => "file"> and C<sym => "symlink">.

I<file> and I<symlink> B<must not include any path>. The path in the
repository is generated from the file name! (Paths in the repository
do not carry any additional information. They are for grouping only
and reduce the number of files in a single directory.)

Optional parameter: C<overwrite => bool>. If true, overwrites old symlinks.
Never overwrites files.

This is a private method.

=cut

sub _add_symlink {
	my $self = shift;
	$self->verbose(2, "Entering _add_symlink");
	my %args = @_;
	my $file = $args{file};
	my $sym = $args{sym};

	# We do not want any user defined directories.
	# Why? Because they would end up in the database with
	# system-specific path separators. BANG!
	(undef, undef, $file) = splitpath($file);
	(undef, undef, $sym)  = splitpath($sym);

	# get the directory in the repository.
	(undef, undef, my $filearch, my $filepver) = PAR::Dist::parse_dist_name($file);
	(undef, undef, my $symarch, my $sympver) = PAR::Dist::parse_dist_name($sym);
	my $filedir = catdir( $filearch, $filepver );
	my $symdir  = catdir( $symarch, $sympver );
	my $file_full = catfile( $filedir, $file );
	my $sym_full  = catfile( $symdir, $sym );
	
	my $overwrite = $args{overwrite};

	unless (eval {symlink("", ""); 1}) {
		croak "Symlinks are not supported on this system!";
	}

	# get the symlinks dbm while in the old path
	my ($shash) = $self->symlinks_dbm;

	my $old_dir = Cwd::cwd();
	chdir($self->{path});

	# symlink exists
	if ( -l $sym_full ) {
		$self->verbose(1, "Symlink '$sym' exists. Overwrite is set to ".($overwrite?1:0));
		chdir($old_dir), return undef if not $overwrite;
		$self->_remove_symlink(sym => $sym);
	}

	# is a file
	if (-f $sym_full and not -l $sym_full) {
		$self->verbose(1, "Symlink '$sym' is a file. Not overwriting");
		chdir($old_dir), return undef;# if not $overwrite;
		# Files always take precedence over symlinks.
	}
	
	symlink(catdir( File::Spec->updir, File::Spec->updir, $file_full ), $sym_full)
	  or die "Could not create symlink from (full repo paths) '$sym_full' to file '$file_full'";

	$shash->{$file} = [] if not defined $shash->{$file};
	push @{$shash->{$file}}, $sym;

	chdir($old_dir);
	
	return 1;
}


=head2 _update_info_version

Writes the YAML repository info file and upgrades the
repository version to the current version.

Should be used with care and considered a private method.

=cut

sub _update_info_version {
    my $self = shift;
	$self->verbose(2, "Entering _update_info_version");
    my $yaml = $self->{info};
    $yaml->{repository_version} = $VERSION;
	my $info_file = catfile($self->{path}, PAR::Repository::REPOSITORY_INFO_FILE());
    unless ($yaml->write($info_file)) {
        croak("Could not write repository info YAML file to '$info_file'.");
    }
    return 1;
}

=head2 _remove_files_from_db

First argument is the reference to the modules or
scripts DBM hash. Second argument is an array reference to
an array of file names. Removes all mention of those
distribution files (symlinks or actual files) from the
DBM hash. This is a slow operation because the hash
associates in the opposite direction.

If any occurrances have been deleted, this method cleans up
the DBM file.

Returns 1 on success.

This is a private method.

=cut

sub _remove_files_from_db {
    my $self = shift;
    my $db = shift;
    my $files = shift;
    
	my %files = map {($_ => undef)} @$files;
    my $deleted = 0;
	foreach my $namespace_or_script (keys %$db) {
		my $in_dists = $db->{$namespace_or_script};
		foreach my $distfile (keys %$in_dists) {
			if (exists $files{$distfile}) {
                $deleted++;
				delete $in_dists->{$distfile};
			}
		}
		# is empty? namespace no more in repository?
		if (keys(%$in_dists) == 0) {
            $deleted++;
			delete $db->{$namespace_or_script};
		}
	}

    if ($deleted) {
        # recover disk space. See DBM::Deep docs.
        tied(%$db)->optimize();
    }
    
    return 1;
}


=head2 _remove_symlink

Removes a symlink from the repository.
Parameters: C<sym => "full/path/in/repo">.

This is a private method.

=cut

sub _remove_symlink {
	my $self = shift;
	$self->verbose(2, "Entering _remove_symlink");
	my %args = @_;

	my $sym = $args{sym};

	# We do not want any user defined directories.
	# Why? Because they would end up in the database with
	# system-specific path separators. BANG!
	(undef, undef, $sym)  = splitpath($sym);

	# get the directory in the repository.
	(undef, undef, my $symarch, my $sympver) = PAR::Dist::parse_dist_name($sym);
	my $symdir  = catdir( $symarch, $sympver );
	my $sym_full  = catfile( $symdir, $sym );
	

	# change to repo path
	my $old_dir = Cwd::cwd();
	chdir($self->{path});

	my ($shash) = $self->symlinks_dbm;
	
	if (not -l $sym_full) {
		$self->verbose(1, "Symlink '$sym' doesn't exist");
		chdir($old_dir);
		return ();
	}

	# remove references to that symlink from the db
	$self->verbose(3, "Removing all references to symlink from DBM");
	foreach my $file (keys %{$shash}) {
		my $syms = $shash->{$file};
		@$syms = grep {$_ ne $sym} @$syms;
	}

	$self->verbose(3, "Removing symlink '$sym'");
	unlink($sym_full) or (chdir($old_dir), return ());

	chdir($old_dir);

	return 1;
}


sub _get_target_file {
	my $self = shift;
	my $method = shift;
	my %args = %{shift()};
	  
	$self->verbose(2, "Entering _get_target_file()");
	
	my ($distname, $distver, $arch, $perlver);
	
	if (grep {!defined($_)} @args{qw/distname distversion arch perlversion/}) {
		$self->verbose(3, "Did not get all distribution information as parameters. Parsing distribution name");
		my ($v, $p, $f) = splitpath($args{file});
		($distname, $distver, $arch, $perlver) = PAR::Dist::parse_dist_name($f);
	}

	$distname = $args{distname} if defined $args{distname};
	$distver  = $args{distversion} if defined $args{distversion};
	$arch     = $args{arch} if defined $args{arch};
	$perlver  = $args{perlversion} if defined $args{perlversion};

	croak("Could not determine distribution name") if not defined $distname;
	croak("Could not determine distribution version") if not defined $distver;
	croak("Could not determine distribution architecture") if not defined $arch;
	croak("Could not determine distribution perl version") if not defined $perlver;
	my $target_file = join('-', $distname, $distver, $arch, $perlver).".par";
	$self->verbose(3, "Target file will be '$target_file'");

	return($target_file, $distname, $distver, $arch, $perlver);
}


sub DESTROY {
	my $self = shift;
	$self->verbose(2, "Entering DESTROY {}");
	
	$self->close_modules_dbm;
	$self->close_symlinks_dbm;
}



1;
__END__

=head1 SEE ALSO

This module inherits from L<PAR::Repository::DBM>,
L<PAR::Repository::Zip>, L<PAR::Repository::Query>,
L<PAR::Repository::ScanPAR>

This module is directly related to the C<PAR> project. You need to have
basic familiarity with it.

See L<PAR>, L<PAR::Dist>, etc.

L<PAR::WebStart> is doing something similar but is otherwise unrelated.

=head1 AUTHOR

Steffen Müller, E<lt>smueller@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Steffen Müller

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.6 or,
at your option, any later version of Perl 5 you may have available.

=cut
