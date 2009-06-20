package Archive::Zip::Archive;

# Represents a generic ZIP archive

use strict;
use File::Path;
use File::Find ();
use File::Spec ();
use File::Copy ();
use File::Basename;
use Cwd;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.27_01';
    @ISA     = qw( Archive::Zip );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

# Note that this returns undef on read errors, else new zip object.

sub new {
    my $class = shift;
    my $self  = bless(
        {
            'diskNumber'                            => 0,
            'diskNumberWithStartOfCentralDirectory' => 0,
            'numberOfCentralDirectoriesOnThisDisk'  => 0, # shld be # of members
            'numberOfCentralDirectories'            => 0, # shld be # of members
            'centralDirectorySize' => 0,    # must re-compute on write
            'centralDirectoryOffsetWRTStartingDiskNumber' =>
              0,                            # must re-compute
            'writeEOCDOffset'             => 0,
            'writeCentralDirectoryOffset' => 0,
            'zipfileComment'              => '',
            'eocdOffset'                  => 0,
            'fileName'                    => ''
        },
        $class
    );
    $self->{'members'} = [];
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{'fileName'} : shift;
    if ($fileName) {
        my $status = $self->read($fileName);
        return $status == AZ_OK ? $self : undef;
    }
    return $self;
}

sub storeSymbolicLink {
    my $self = shift;
    $self->{'storeSymbolicLink'} = shift;
}

sub members {
    @{ shift->{'members'} };
}

sub numberOfMembers {
    scalar( shift->members() );
}

sub memberNames {
    my $self = shift;
    return map { $_->fileName() } $self->members();
}

# return ref to member with given name or undef
sub memberNamed {
    my $self     = shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{fileName} : shift;
    foreach my $member ( $self->members() ) {
        return $member if $member->fileName() eq $fileName;
    }
    return undef;
}

sub membersMatching {
    my $self    = shift;
    my $pattern = ( ref( $_[0] ) eq 'HASH' ) ? shift->{regex} : shift;
    return grep { $_->fileName() =~ /$pattern/ } $self->members();
}

sub diskNumber {
    shift->{'diskNumber'};
}

sub diskNumberWithStartOfCentralDirectory {
    shift->{'diskNumberWithStartOfCentralDirectory'};
}

sub numberOfCentralDirectoriesOnThisDisk {
    shift->{'numberOfCentralDirectoriesOnThisDisk'};
}

sub numberOfCentralDirectories {
    shift->{'numberOfCentralDirectories'};
}

sub centralDirectorySize {
    shift->{'centralDirectorySize'};
}

sub centralDirectoryOffsetWRTStartingDiskNumber {
    shift->{'centralDirectoryOffsetWRTStartingDiskNumber'};
}

sub zipfileComment {
    my $self    = shift;
    my $comment = $self->{'zipfileComment'};
    if (@_) {
        my $new_comment = ( ref( $_[0] ) eq 'HASH' ) ? shift->{comment} : shift;
        $self->{'zipfileComment'} = pack( 'C0a*', $new_comment );    # avoid unicode
    }
    return $comment;
}

sub eocdOffset {
    shift->{'eocdOffset'};
}

# Return the name of the file last read.
sub fileName {
    shift->{'fileName'};
}

sub removeMember {
    my $self    = shift;
    my $member  = ( ref( $_[0] ) eq 'HASH' ) ? shift->{memberOrName} : shift;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    my @newMembers = grep { $_ != $member } $self->members();
    $self->{'members'} = \@newMembers;
    return $member;
}

sub replaceMember {
    my $self       = shift;
    my $oldMember  = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{memberOrName} : shift;
    my $newMember  = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{newMember} : shift;
    $oldMember = $self->memberNamed($oldMember) unless ref($oldMember);
    return undef unless $oldMember;
    return undef unless $newMember;
    my @newMembers =
      map { ( $_ == $oldMember ) ? $newMember : $_ } $self->members();
    $self->{'members'} = \@newMembers;
    return $oldMember;
}

sub extractMember {
    my $self   = shift;
    my $member  = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{memberOrName} : shift;
    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    my $name  = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{extractedName} : shift;  # local FS name if given
    my ( $volumeName, $dirName, $fileName );
    if ( defined($name) ) {
        ( $volumeName, $dirName, $fileName ) = File::Spec->splitpath($name);
        $dirName = File::Spec->catpath( $volumeName, $dirName, '' );
    }
    else {
        $name = $member->fileName();
        ( $dirName = $name ) =~ s{[^/]*$}{};
        $dirName = Archive::Zip::_asLocalName($dirName);
        $name    = Archive::Zip::_asLocalName($name);
    }
    if ( $dirName && !-d $dirName ) {
        mkpath($dirName);
        return _ioError("can't create dir $dirName") if ( !-d $dirName );
    }
    my $rc = $member->extractToFileNamed( $name, @_ );

    # TODO refactor this fix into extractToFileNamed()
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub extractMemberWithoutPaths {
    my $self   = shift;
    my $member = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{memberOrName} : shift;
    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    return AZ_OK if $member->isDirectory();
    my $name = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{extractedName} : shift;
    unless ($name) {
        $name = $member->fileName();
        $name =~ s{.*/}{};    # strip off directories, if any
        $name = Archive::Zip::_asLocalName($name);
    }
    my $rc = $member->extractToFileNamed( $name, @_ );
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub addMember {
    my $self       = shift;
    my $newMember  = ( ref( $_[0] ) eq 'HASH' ) ? shift->{member} : shift;
    push( @{ $self->{'members'} }, $newMember ) if $newMember;
    return $newMember;
}

sub addFile {
    my $self      = shift;

    my ( $fileName, $newName, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fileName         = $_[0]->{fileName};
        $newName          = $_[0]->{newName};
        $compressionLevel = $_[0]->{desiredCompressionLevel};
    }
    else {
        ( $fileName, $newName, $compressionLevel ) = @_;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newFromFile( $fileName, $newName );
    $newMember->desiredCompressionLevel($compressionLevel);
    if ( $self->{'storeSymbolicLink'} && -l $fileName ) {
        my $newMember = $self->ZIPMEMBERCLASS->newFromString(readlink $fileName, $newName);
        # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    return $newMember;
}

sub addString {
    my $self = shift;
    my @args;
    if ( ref( $_[0] ) eq 'HASH' ) {
        push @args, $_[0]->{stringOrStringRef}, $_[0]->{name};
    }
    else {
        @args = @_;
    }
    my $newMember = $self->ZIPMEMBERCLASS->newFromString(@args);
    return $self->addMember($newMember);
}

sub addDirectory {
    my $self    = shift;
    my $name    = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{directoryName} : shift;
    my $newName = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{newName} : shift;
    my $newMember = $self->ZIPMEMBERCLASS->newDirectoryNamed( $name, $newName );
    if ( $self->{'storeSymbolicLink'} && -l $name ) {
        my $link = readlink $name;
        ( $newName =~ s{/$}{} ) if $newName; # Strip trailing /
        my $newMember = $self->ZIPMEMBERCLASS->newFromString($link, $newName);
        # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    return $newMember;
}

# add either a file or a directory.

sub addFileOrDirectory {
    my $self    = shift;
    my $name    = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{name} : shift;
    my $newName = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{newName} : shift;
    $name =~ s{/$}{};
    if ( $newName ) {
        $newName =~ s{/$}{};
    } else {
        $newName = $name;
    }
    if ( -f $name ) {
        return $self->addFile( $name, $newName );
    }
    elsif ( -d $name ) {
        return $self->addDirectory( $name, $newName );
    }
    else {
        return _error("$name is neither a file nor a directory");
    }
}

sub contents {
    my $self        = shift;
    my $member      = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{memberOrMemberName} : shift;
    my $newContents = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{newContents} : shift;
    return _error('No member name given') unless $member;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    return $member->contents($newContents);
}

sub writeToFileNamed {
    my $self     = shift;
    my $fileName =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{fileName} : shift; # local FS format
    foreach my $member ( $self->members() ) {
        if ( $member->_usesFileNamed($fileName) ) {
            return _error( "$fileName is needed by member "
                  . $member->fileName()
                  . "; consider using overwrite() or overwriteAs() instead." );
        }
    }
    my ( $status, $fh ) = _newFileHandle( $fileName, 'w' );
    return _ioError("Can't open $fileName for write") unless $status;
    my $retval = $self->writeToFileHandle( $fh, 1 );
    $fh->close();
    $fh = undef;

    return $retval;
}

# It is possible to write data to the FH before calling this,
# perhaps to make a self-extracting archive.
sub writeToFileHandle {
    my $self = shift;
    my $fh   = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{fileHandle} : shift;
    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();

    my $fhIsSeekable;
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fhIsSeekable =
          exists( $_[0]->{seekable} ) ? $_[0]->{seekable} : _isSeekable($fh);
    }
    else {
        $fhIsSeekable = @_ ? shift : _isSeekable($fh);
    }

    _binmode($fh);

    # Find out where the current position is.
    my $offset = $fhIsSeekable ? $fh->tell() : 0;
    $offset = 0 if $offset < 0;

    foreach my $member ( $self->members() ) {
        my $retval = $member->_writeToFileHandle( $fh, $fhIsSeekable, $offset );
        $member->endRead();
        return $retval if $retval != AZ_OK;
        $offset += $member->_localHeaderSize() + $member->_writeOffset();
        $offset +=
          $member->hasDataDescriptor()
          ? DATA_DESCRIPTOR_LENGTH + SIGNATURE_LENGTH
          : 0;

        # changed this so it reflects the last successful position
        $self->{'writeCentralDirectoryOffset'} = $offset;
    }
    return $self->writeCentralDirectory($fh);
}

# Write zip back to the original file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwrite {
    my $self = shift;
    return $self->overwriteAs( $self->{'fileName'} );
}

# Write zip to the specified file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwriteAs {
    my $self    = shift;
    my $zipName = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{newName} : shift;
    return _error("no filename in overwriteAs()") unless defined($zipName);

    my ( $fh, $tempName ) = Archive::Zip::tempFile();
    return _error( "Can't open temp file", $! ) unless $fh;

    ( my $backupName = $zipName ) =~ s{(\.[^.]*)?$}{.zbk};

    my $status = $self->writeToFileHandle($fh);
    $fh->close();
    $fh = undef;

    if ( $status != AZ_OK ) {
        unlink($tempName);
        _printError("Can't write to $tempName");
        return $status;
    }

    my $err;

    # rename the zip
    if ( -f $zipName && !rename( $zipName, $backupName ) ) {
        $err = $!;
        unlink($tempName);
        return _error( "Can't rename $zipName as $backupName", $err );
    }

    # move the temp to the original name (possibly copying)
    unless ( File::Copy::move( $tempName, $zipName ) ) {
        $err = $!;
        rename( $backupName, $zipName );
        unlink($tempName);
        return _error( "Can't move $tempName to $zipName", $err );
    }

    # unlink the backup
    if ( -f $backupName && !unlink($backupName) ) {
        $err = $!;
        return _error( "Can't unlink $backupName", $err );
    }

    return AZ_OK;
}

# Used only during writing
sub _writeCentralDirectoryOffset {
    shift->{'writeCentralDirectoryOffset'};
}

sub _writeEOCDOffset {
    shift->{'writeEOCDOffset'};
}

# Expects to have _writeEOCDOffset() set
sub _writeEndOfCentralDirectory {
    my ( $self, $fh ) = @_;

    $self->_print($fh, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING)
      or return _ioError('writing EOCD Signature');
    my $zipfileCommentLength = length( $self->zipfileComment() );

    my $header = pack(
        END_OF_CENTRAL_DIRECTORY_FORMAT,
        0,                          # {'diskNumber'},
        0,                          # {'diskNumberWithStartOfCentralDirectory'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectoriesOnThisDisk'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectories'},
        $self->_writeEOCDOffset() - $self->_writeCentralDirectoryOffset(),
        $self->_writeCentralDirectoryOffset(),
        $zipfileCommentLength
    );
    $self->_print($fh, $header)
      or return _ioError('writing EOCD header');
    if ($zipfileCommentLength) {
        $self->_print($fh,  $self->zipfileComment() )
          or return _ioError('writing zipfile comment');
    }
    return AZ_OK;
}

# $offset can be specified to truncate a zip file.
sub writeCentralDirectory {
    my $self   = shift;
    my $fh     = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{fileHandle} : shift;
    my $offset = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{offset} : shift;

    if ( defined($offset) ) {
        $self->{'writeCentralDirectoryOffset'} = $offset;
        $fh->seek( $offset, IO::Seekable::SEEK_SET )
          or return _ioError('seeking to write central directory');
    }
    else {
        $offset = $self->_writeCentralDirectoryOffset();
    }

    foreach my $member ( $self->members() ) {
        my $status = $member->_writeCentralDirectoryFileHeader($fh);
        return $status if $status != AZ_OK;
        $offset += $member->_centralDirectoryHeaderSize();
        $self->{'writeEOCDOffset'} = $offset;
    }
    return $self->_writeEndOfCentralDirectory($fh);
}

sub read {
    my $self     = shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{fileName} : shift;
    return _error('No filename given') unless $fileName;
    my ( $status, $fh ) = _newFileHandle( $fileName, 'r' );
    return _ioError("opening $fileName for read") unless $status;

    $status = $self->readFromFileHandle( $fh, $fileName );
    return $status if $status != AZ_OK;

    $fh->close();
    $self->{'fileName'} = $fileName;
    return AZ_OK;
}

sub readFromFileHandle {
    my $self     = shift;
    my $fh       = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{fileHandle} : shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{fileName} : shift;
    $fileName = $fh unless defined($fileName);
    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();

    _binmode($fh);
    $self->{'fileName'} = "$fh";

    # TODO: how to support non-seekable zips?
    return _error('file not seekable')
      unless _isSeekable($fh);

    $fh->seek( 0, 0 );    # rewind the file

    my $status = $self->_findEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    my $eocdPosition = $fh->tell();

    $status = $self->_readEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    $fh->seek( $eocdPosition - $self->centralDirectorySize(),
        IO::Seekable::SEEK_SET )
      or return _ioError("Can't seek $fileName");

    # Try to detect garbage at beginning of archives
    # This should be 0
    $self->{'eocdOffset'} = $eocdPosition - $self->centralDirectorySize() # here
      - $self->centralDirectoryOffsetWRTStartingDiskNumber();

    for ( ; ; ) {
        my $newMember =
          $self->ZIPMEMBERCLASS->_newFromZipFile( $fh, $fileName,
            $self->eocdOffset() );
        my $signature;
        ( $status, $signature ) = _readSignature( $fh, $fileName );
        return $status if $status != AZ_OK;
        last           if $signature == END_OF_CENTRAL_DIRECTORY_SIGNATURE;
        $status = $newMember->_readCentralDirectoryFileHeader();
        return $status if $status != AZ_OK;
        $status = $newMember->endRead();
        return $status if $status != AZ_OK;
        $newMember->_becomeDirectoryIfNecessary();
        push( @{ $self->{'members'} }, $newMember );
    }

    return AZ_OK;
}

# Read EOCD, starting from position before signature.
# Return AZ_OK on success.
sub _readEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;

    # Skip past signature
    $fh->seek( SIGNATURE_LENGTH, IO::Seekable::SEEK_CUR )
      or return _ioError("Can't seek past EOCD signature");

    my $header = '';
    my $bytesRead = $fh->read( $header, END_OF_CENTRAL_DIRECTORY_LENGTH );
    if ( $bytesRead != END_OF_CENTRAL_DIRECTORY_LENGTH ) {
        return _ioError("reading end of central directory");
    }

    my $zipfileCommentLength;
    (
        $self->{'diskNumber'},
        $self->{'diskNumberWithStartOfCentralDirectory'},
        $self->{'numberOfCentralDirectoriesOnThisDisk'},
        $self->{'numberOfCentralDirectories'},
        $self->{'centralDirectorySize'},
        $self->{'centralDirectoryOffsetWRTStartingDiskNumber'},
        $zipfileCommentLength
    ) = unpack( END_OF_CENTRAL_DIRECTORY_FORMAT, $header );

    if ($zipfileCommentLength) {
        my $zipfileComment = '';
        $bytesRead = $fh->read( $zipfileComment, $zipfileCommentLength );
        if ( $bytesRead != $zipfileCommentLength ) {
            return _ioError("reading zipfile comment");
        }
        $self->{'zipfileComment'} = $zipfileComment;
    }

    return AZ_OK;
}

# Seek in my file to the end, then read backwards until we find the
# signature of the central directory record. Leave the file positioned right
# before the signature. Returns AZ_OK if success.
sub _findEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;
    my $data = '';
    $fh->seek( 0, IO::Seekable::SEEK_END )
      or return _ioError("seeking to end");

    my $fileLength = $fh->tell();
    if ( $fileLength < END_OF_CENTRAL_DIRECTORY_LENGTH + 4 ) {
        return _formatError("file is too short");
    }

    my $seekOffset = 0;
    my $pos        = -1;
    for ( ; ; ) {
        $seekOffset += 512;
        $seekOffset = $fileLength if ( $seekOffset > $fileLength );
        $fh->seek( -$seekOffset, IO::Seekable::SEEK_END )
          or return _ioError("seek failed");
        my $bytesRead = $fh->read( $data, $seekOffset );
        if ( $bytesRead != $seekOffset ) {
            return _ioError("read failed");
        }
        $pos = rindex( $data, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING );
        last
          if ( $pos >= 0
            or $seekOffset == $fileLength
            or $seekOffset >= $Archive::Zip::ChunkSize );
    }

    if ( $pos >= 0 ) {
        $fh->seek( $pos - $seekOffset, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to EOCD");
        return AZ_OK;
    }
    else {
        return _formatError("can't find EOCD signature");
    }
}

# Used to avoid taint problems when chdir'ing.
# Not intended to increase security in any way; just intended to shut up the -T
# complaints.  If your Cwd module is giving you unreliable returns from cwd()
# you have bigger problems than this.
sub _untaintDir {
    my $dir = shift;
    $dir =~ m/\A(.+)\z/s;
    return $1;
}

sub addTree {
    my $self = shift;
    my ( $root, $dest, $pred, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{dest};
        $pred             = $_[0]->{choose};
        $compressionLevel = $_[0]->{desiredCompressionLevel};
    }
    else {
        ( $root, $dest, $pred, $compressionLevel ) = @_;
    }
    return _error("root arg missing in call to addTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r } unless defined($pred);

    my @files;
    my $startDir = _untaintDir( cwd() );

    return _error( 'undef returned by _untaintDir on cwd ', cwd() )
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push( @files, $File::Find::name ) if (&$pred);
        chdir($dir);
    };

    File::Find::find( $wanted, $root );

    my $rootZipName = _asZipDirName( $root, 1 );    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    $dest = _asZipDirName( $dest, 1 );              # with trailing slash

    foreach my $fileName (@files) {
        my $isDir = -d $fileName;

        # normalize, remove leading ./
        my $archiveName = _asZipDirName( $fileName, $isDir );
        if ( $archiveName eq $rootZipName ) { $archiveName = $dest }
        else { $archiveName =~ s{$pattern}{$dest} }
        next if $archiveName =~ m{^\.?/?$};         # skip current dir
        my $member = $isDir
          ? $self->addDirectory( $fileName, $archiveName )
          : $self->addFile( $fileName, $archiveName );
        $member->desiredCompressionLevel($compressionLevel);

        return _error("add $fileName failed in addTree()") if !$member;
    }
    return AZ_OK;
}

sub addTreeMatching {
    my $self = shift;
    my ( $root, $dest, $pattern, $pred, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{dest};
        $pattern          = $_[0]->{pattern};
        $pred             = $_[0]->{choose};
        $compressionLevel = $_[0]->{desiredCompressionLevel};
    }
    else {
        ( $root, $dest, $pattern, $pred, $compressionLevel ) = @_;
    }
    return _error("root arg missing in call to addTreeMatching()")
      unless defined($root);
    $dest = '' unless defined($dest);
    return _error("pattern missing in call to addTreeMatching()")
      unless defined($pattern);
    my $matcher =
      $pred ? sub { m{$pattern} && &$pred } : sub { m{$pattern} && -r };
    return $self->addTree( $root, $dest, $matcher, $compressionLevel );
}

# $zip->extractTree( $root, $dest [, $volume] );
#
# $root and $dest are Unix-style.
# $volume is in local FS format.
#
sub extractTree {
    my $self = shift;
    my $root = shift;    # Zip format
    $root = '' unless defined($root);
    my $dest = shift;    # Zip format
    $dest = './' unless defined($dest);
    my $volume  = shift;                              # optional
    my $pattern = "^\Q$root";
    my @members = $self->membersMatching($pattern);

    foreach my $member (@members) {
        my $fileName = $member->fileName();           # in Unix format
        $fileName =~ s{$pattern}{$dest};    # in Unix format
                                            # convert to platform format:
        $fileName = Archive::Zip::_asLocalName( $fileName, $volume );
        my $status = $member->extractToFileNamed($fileName);
        return $status if $status != AZ_OK;
    }
    return AZ_OK;
}

# $zip->updateMember( $memberOrName, $fileName );
# Returns (possibly updated) member, if any; undef on errors.

sub updateMember {
    my $self      = shift;

    my ( $oldMember, $fileName, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $oldMember        = $_[0]->{memberOrName};
        $fileName         = $_[0]->{fileOrDirectoryName};
        $compressionLevel = $_[0]->{desiredCompressionLevel};
    }
    else {
        ( $oldMember, $fileName, $compressionLevel ) = @_;
    }

    if ( !defined($fileName) ) {
        _error("updateMember(): missing fileName argument");
        return undef;
    }

    my @newStat = stat($fileName);
    if ( !@newStat ) {
        _ioError("Can't stat $fileName");
        return undef;
    }

    my $isDir = -d _;

    my $memberName;

    if ( ref($oldMember) ) {
        $memberName = $oldMember->fileName();
    }
    else {
        $oldMember = $self->memberNamed( $memberName = $oldMember )
          || $self->memberNamed( $memberName =
              _asZipDirName( $oldMember, $isDir ) );
    }

    if ( defined($oldMember) ) {
        $oldMember->desiredCompressionLevel($compressionLevel);
    }

    unless ( defined($oldMember)
        && $oldMember->lastModTime() == $newStat[9]
        && $oldMember->isDirectory() == $isDir
        && ( $isDir || ( $oldMember->uncompressedSize() == $newStat[7] ) ) )
    {

        # create the new member
        my $newMember = $isDir
          ? $self->ZIPMEMBERCLASS->newDirectoryNamed( $fileName, $memberName )
          : $self->ZIPMEMBERCLASS->newFromFile( $fileName, $memberName );
        $newMember->desiredCompressionLevel($compressionLevel);

        unless ( defined($newMember) ) {
            _error("creation of member $fileName failed in updateMember()");
            return undef;
        }

        # replace old member or append new one
        if ( defined($oldMember) ) {
            $self->replaceMember( $oldMember, $newMember );
        }
        else { $self->addMember($newMember); }

        return $newMember;
    }

    return $oldMember;
}

# $zip->updateTree( $root, [ $dest, [ $pred [, $mirror]]] );
#
# This takes the same arguments as addTree, but first checks to see
# whether the file or directory already exists in the zip file.
#
# If the fourth argument $mirror is true, then delete all my members
# if corresponding files weren't found.

sub updateTree {
    my $self = shift;
    my ( $root, $dest, $pred, $mirror, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{dest};
        $pred             = $_[0]->{choose};
        $mirror           = $_[0]->{mirror};
        $compressionLevel = $_[0]->{desiredCompressionLevel};
    }
    else {
        ( $root, $dest, $pred, $mirror, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to updateTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r } unless defined($pred);

    $dest = _asZipDirName( $dest, 1 );
    my $rootZipName = _asZipDirName( $root, 1 );    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    my @files;
    my $startDir = _untaintDir( cwd() );

    return _error( 'undef returned by _untaintDir on cwd ', cwd() )
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push( @files, $File::Find::name ) if (&$pred);
        chdir($dir);
    };

    File::Find::find( $wanted, $root );

    # Now @files has all the files that I could potentially be adding to
    # the zip. Only add the ones that are necessary.
    # For each file (updated or not), add its member name to @done.
    my %done;
    foreach my $fileName (@files) {
        my @newStat = stat($fileName);
        my $isDir   = -d _;

        # normalize, remove leading ./
        my $memberName = _asZipDirName( $fileName, $isDir );
        if ( $memberName eq $rootZipName ) { $memberName = $dest }
        else { $memberName =~ s{$pattern}{$dest} }
        next if $memberName =~ m{^\.?/?$};    # skip current dir

        $done{$memberName} = 1;
        my $changedMember = $self->updateMember( $memberName, $fileName );
        $changedMember->desiredCompressionLevel($compressionLevel);
        return _error("updateTree failed to update $fileName")
          unless ref($changedMember);
    }

    # @done now has the archive names corresponding to all the found files.
    # If we're mirroring, delete all those members that aren't in @done.
    if ($mirror) {
        foreach my $member ( $self->members() ) {
            $self->removeMember($member)
              unless $done{ $member->fileName() };
        }
    }

    return AZ_OK;
}

1;
