use strict;
use warnings;
use Test::More tests => 1+3+46;
BEGIN { use_ok('PAR::Repository') };

chdir('t') if -d 't';
use lib 'lib';
# requires 3 tests to boot
require RepoTest;
#$RepoTest::Debug = 1;

my $tdir = RepoTest->TempDir;
my $repodir = File::Spec->catdir($tdir, 'repo');

chdir($tdir);

# create new repo, assert it's okay
ok(!RepoTest->RunParrepo('create'), 'parrepo create did not die');
ok(-d $repodir, 'parrepo create created a repo dir');
RepoTest->TestRepoFilesExist($repodir);

my $testDists = RepoTest->TestDists;

my $parfile = 'Test-Kit-0.02-any_arch-any_version.par';
my @test_kit = grep /\Q$parfile\E/, @$testDists;
ok(scalar(@test_kit) == 1, 'found exactly one Test-Kit dist for testing');

####################
sub check_injection {
  my $file = shift || $parfile;
  my ($dn, $dv, $arch, $pv) = PAR::Dist::parse_dist_name($file);
  ok(
    -f File::Spec->catfile($repodir, $arch, $pv, $file),
    'par was injected'
  );

  # test whether the stuff is in the repository now
  my $repo = RepoTest->CanOpenRepo($repodir);
  is_deeply(
    $repo->query_module(regex => '^Test::Kit$'),
    [$file, '0.02'],
  );

  is_deeply(
    $repo->query_dist(regex => '^Test-Kit'),
    [
      $file, 
      {
        'Test::Kit' => '0.02',
        'Test::Kit::Result' => '0.02',
        'Test::Kit::Features' => '0.02',
      },
    ]
  );
}
####################
sub check_removal {
  my $file = shift || $parfile;
  my ($dn, $dv, $arch, $pv) = PAR::Dist::parse_dist_name($file);
  my $repo = RepoTest->CanOpenRepo($repodir);
  ok(
    !-f File::Spec->catfile($repodir, $arch, $pv, $file),
    'par was removed'
  );
  is_deeply(
    $repo->query_module(regex => '^Test::Kit$'),
    [],
  );
  is_deeply(
    $repo->query_dist(regex => '^Test-Kit'),
    []
  );
}

# test injection and removal via parrepo
ok(!RepoTest->RunParrepo('inject', '-f', $test_kit[0]), "parrepo didn't complain about injection");
check_injection();
ok(!RepoTest->RunParrepo('remove', '-f', $parfile), 'no error from remove');
check_removal();

# now re-add it using the API
my $repo = RepoTest->CanOpenRepo($repodir);
ok($repo->inject('file', $test_kit[0]), "api injection succeeded");
check_injection();
ok ($repo->remove(file => $parfile), 'no error from remove');
check_removal();

# now use the api slightly differently
SCOPE: {
  my $file = $parfile;
  $file =~ s/any_version/5.8.5/ or die;
  $file =~ s/any_arch/myarch/ or die;
  ok($repo->inject('file' => $test_kit[0], arch => 'myarch', perlversion => '5.8.5'), "api injection succeeded");
  check_injection($file);
  ok ($repo->remove(file => $file), 'no error from remove');
  check_removal($file);
}

