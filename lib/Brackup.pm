package Brackup;
use strict;
use vars qw($VERSION);
$VERSION = '0.91';

use Brackup::Config;
use Brackup::File;
use Brackup::Chunk;
use Brackup::DigestDatabase;
use Brackup::Backup;
use Brackup::Root;     # aka "source"
use Brackup::Restore;
use Brackup::Target;
use Brackup::BackupStats;

1;
