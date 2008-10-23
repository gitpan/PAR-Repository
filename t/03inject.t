use strict;
use warnings;
use Test::More tests => 1+3+64+18+1;
BEGIN { use_ok('PAR::Repository') };

chdir('t') if -d 't';
use lib 'lib';
# requires 3 tests to boot
require RepoTest;
require RepoTest::TestKit;
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

# test injection and removal via parrepo
ok(!RepoTest->RunParrepo('inject', '-f', $test_kit[0]), "parrepo didn't complain about injection");
RepoTest::TestKit->check_injection($parfile);
RepoTest::TestKit->check_symlinks();
ok(!RepoTest->RunParrepo('remove', '-f', $parfile), 'no error from remove');
RepoTest::TestKit->check_removal($parfile);
RepoTest::TestKit->check_symlinks();

# now re-add it using the API
my $repo = RepoTest->CanOpenRepo($repodir);
ok($repo->inject('file', $test_kit[0]), "api injection succeeded");
RepoTest::TestKit->check_injection($parfile);
RepoTest::TestKit->check_symlinks();
ok ($repo->remove(file => $parfile), 'no error from remove');
RepoTest::TestKit->check_removal($parfile);
RepoTest::TestKit->check_symlinks();

# now use the api slightly differently
SCOPE: {
  my $file = $parfile;
  $file =~ s/any_version/5.8.5/ or die;
  $file =~ s/any_arch/myarch/ or die;
  ok($repo->inject('file' => $test_kit[0], arch => 'myarch', perlversion => '5.8.5'), "api injection succeeded");
  RepoTest::TestKit->check_injection($file);
  RepoTest::TestKit->check_symlinks();
  ok ($repo->remove(file => $file), 'no error from remove');
  RepoTest::TestKit->check_removal($file);
  RepoTest::TestKit->check_symlinks();
}

# now use the api with symlinks
SCOPE: {
  my $file = $parfile;
  $file =~ s/any_version/5.8.5/ or die;
  $file =~ s/any_arch/myarch/ or die;
  my $file2 = $parfile;
  $file2 =~ s/any_version/5.8.5/ or die;
  ok($repo->inject('file' => $test_kit[0], arch => 'myarch', perlversion => '5.8.5', any_arch => 1), "api injection succeeded");
  RepoTest::TestKit->check_injection([$file,$file2]);
  RepoTest::TestKit->check_symlinks(
    { 'Test-Kit-0.02-myarch-5.8.5.par' => ['Test-Kit-0.02-any_arch-5.8.5.par'] }
  );
  ok ($repo->remove(file => $file), 'no error from remove');
  RepoTest::TestKit->check_removal($file);
  RepoTest::TestKit->check_symlinks();
}

