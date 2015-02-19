#!/usr/bin/perl
#

use strict;
use warnings;

use Data::Dumper;

use open qw< :encoding(UTF-8) >;
use JSON::PP;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use UUID::Tiny ':std';
use File::Temp qw/ tempfile /;

my $json = JSON::PP->new->utf8->pretty;

my $webapps_system_location = "/system/b2g/webapps";
my $webapps_json_location = "/data/local/webapps/webapps.json";

system('adb wait-for-device');
system('adb root');
system('adb remount');

my $webapps_json = `adb shell cat $webapps_json_location`;
my $webapps = $json->decode($webapps_json);

my $manifest = read_manifest();
my $customizations = $manifest->{customizations};

my $name = $manifest->{name};

my $code = find_app_code($name) // install_app();
update_app($code);
rehash_manifest();

sub read_manifest {
  my $manifest_file = "manifest.webapp";
  my $manifest_string = do {
      local $/ = undef;
      open my $fh, "<", $manifest_file
          or die "could not open $manifest_file: $!";
      <$fh>;
  };
  my $manifest = $json->decode($manifest_string);
  return $manifest;
}

sub find_app_code {
  my $name = shift;

  for my $code (keys %$webapps) {
    my $appInfo = $webapps->{$code};
    return $code if $appInfo->{name} eq $name;
  }
  return;
}

sub update_app {
  my $code = shift;
  print "Updating app $code\n";

  my $location = "$webapps_system_location/$code";

  my $archive = package_app();

  system("adb push manifest.webapp $location/manifest.webapp");
  system("adb push $archive $location/application.zip");
  system("adb shell chmod 755 $webapps_system_location $location");
  system("adb shell chmod 644 $location/manifest.webapp $location/application.zip");

  unlink($archive);
}

sub package_app {
  my $zip = Archive::Zip->new();
  $zip->addFile('manifest.webapp');

  my @additionalFiles = map { ( @{ $_->{css} // [] }, @{ $_->{scripts} // [] } ) } @$customizations;
  for my $file (@additionalFiles) {
    $zip->addFile("./$file");
  }

  my ($fh, $name) = Archive::Zip::tempFile();
  unless ($zip->writeToFileHandle( $fh ) == AZ_OK) {
    die "Couldn't write the zip file";
  }

  $fh->close();

  return $name;
}

sub find_next_local_id {
  my @used_values = grep { $_ > 100 and $_ < 1000 } map { $_->{localId} } values %$webapps;
  for my $id (101..999) {
    return $id unless ($id ~~ @used_values);
  }
  die("Couldn't find a suitable localId");
}

sub install_app {
  var $code = create_uuid();
  my $location = "$webapps_system_location/$code";

  system("adb shell mkdir $location");
  $webapps->{$code} = {
    origin => "app://$code",
    installOrigin => "app://$code",
    manifestURL => "app://$code/manifest.webapp",
    appStatus => 3, # TODO CERTIFIED or PRIVILEGED
    kind => "packaged",
    removable => JSON::PP::true,
    id  => $code,
    basePath => $webapps_system_location,
    localId => find_next_local_id(),
    sideloaded => JSON::PP::true,
    name => $manifest->{name},
    role => $manifest->{role},
    enabled => JSON::PP::true,
    downloading => JSON::PP::false,
    readyToApplyDownload => JSON::PP::false
  };

  my $webapps_json = $json->encode( $webapps );
  my ($fh, $fname) = tempfile();
  print $fh $webapps_json;
  $fh->close();
  system('adb shell push $fname $webapps_json_location');
  unlink($fname);

  return $code;
}

sub rehash_manifest {
  open(my $adb, "|adb shell");
  print $adb q{
    stop b2g
    cd /data/b2g/mozilla/*.default/
    echo 'user_pref("gecko.buildID", "1");' >> prefs.js
    start b2g
    exit
  };
  close $adb;
}
