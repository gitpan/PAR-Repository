use 5.006;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

if (not $ENV{IGNORE_SYMLINK_WARNINGS} and not eval {symlink("", ""); 1;}) {
	warn <<'HERE';
Your system does not support creation of symbolic links.
Using PAR::Repository on this system to manage a repository
is dangerous because the necessary symbolic links might not
be created.

If you want to ignore this message and continue installing
PAR::Reporitory, please set the environment variable
IGNORE_SYMLINK_WARNING to a true valid and rerun Makefile.PL.
HERE
	exit(1);
}

WriteMakefile(
    NAME              => 'PAR::Repository',
    VERSION_FROM      => 'lib/PAR/Repository.pm', # finds $VERSION
    PREREQ_PM         => {
#'perl'      => '5.6',
		'DBM::Deep' => '0',
		'File::Spec' => '0',
		'File::Path' => '0',
		'File::Temp' => '0',
		'File::Copy' => '0',
        'Archive::Zip' => '0',
		'PAR::Dist' => '0.18',
		'YAML::Syck' => '0.62',
		'version' => '0.50',
		'Pod::Text' => '0',
		'ExtUtils::Manifest' => '0',
    }, # e.g., Module::Name => 1.1
    EXE_FILES => [
      'bin/parrepo',
    ],
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/PAR/Repository.pm', # retrieve abstract from module
       AUTHOR         => 'Steffen Müller <smueller@cpan.org>') : ()),
);
