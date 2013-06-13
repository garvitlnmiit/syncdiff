#!/usr/bin/perl

package SyncDiff::DB 0.01;
use Moose;

extends qw(SyncDiff::Forkable);

#
# Needed to communicate with other modules
#

use SyncDiff::File;
use SyncDiff::Util;

#
# Needed for dealing with DB stuff
#

use DBD::SQLite;
use IO::Socket;
use JSON::XS;
use MIME::Base64;

#
# Debugging
#

use Data::Dumper;

# End includes

#
# moose variables
#

has 'file' => (
		is	=> 'rw',
		isa	=> 'Str',
		);

has 'dbh' => (
		is	=> 'ro',
		isa	=> 'DBI::db',
		writer	=> '_write_dbh',
		);

# End variables

sub connect_and_fork {
	my( $self, $file_to_open ) = @_;

	$self->connect( $file_to_open );
	$self->fork();
} # end connect_and_fork()

sub connect {
	my( $self, $file_to_open ) = @_;

	if( defined $file_to_open ){
		$self->file( $file_to_open );
	}

##	print "DB:connect(): File as it currently exists: |". $self->file ."|\n";

	my $file = $self->file;

	if(
		!defined $file
		||
		$file eq ""
	){
		die("Database file not defined\n");
	}

	my $dbh = DBI->connect(
				"dbi:SQLite:dbname=". $file,
				"",
				"",
				{
					RaiseError => 1,
					AutoCommit => 1,
					PrintError => 0
				}
			);

	$self->_write_dbh( $dbh );

	return;

	#
	# Beyond this is all random testing code
	#

##	print "----------------------------------\n";
##	print Dumper $dbh;
##	print "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n";

	my $select_all = $dbh->prepare("SELECT * FROM files");

	$select_all->execute();

	my $row_ref = $select_all->fetchall_hashref('id');

##	print "----------------------------------\n";
##	print Dumper \$row_ref;
##	print "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n";
	
} # end connect()

#
# Need to override this from Forkable
#
override 'run_child' => sub {
	my( $self ) = @_;

	$self->recv_loop();
}; # end run_child();

sub recv_loop {
	my( $self ) = @_;

	my $PARENT_IPC = $self->PARENT_IPC;
	my $line = undef;

	while( $line = <$PARENT_IPC> ){
		chomp($line);
		my $response = $self->process_request( $line );

##		print "DB:recv_loop() - going to push response back at parent\n";

##		print Dumper $response;
##		print "DB:recv_loop() - pushing...\n";

		if(
			$response eq "0"
		){
			my %temp_resp = (
				ZERO	=> "0",
			);
			$response = \%temp_resp;
		}

##		print "Reference check: ". ref( $response ) ."\n";
##		print Dumper $response;

		my $ref_resp = ref( $response );

		if(
			! defined $ref_resp
			||
			$ref_resp eq "SCALAR"
			||
			$ref_resp eq ""
		){
			my %temp_resp = (
				SCALAR	=> $response,
			);
			$response = \%temp_resp;
		}

##		print "Why is this a dud:\n";
##		print Dumper $response;

		my $json_response = encode_json( $response );
		print $PARENT_IPC $json_response ."\n";
	}
} # end recv_loop()

sub process_request {
	my( $self, $line ) = @_;

##	print "-----------------------\n";
##	print "DB:process_request - line:\n";
##	print Dumper $line;
##	print "^^^^^^^^^^^^^^^^^^^^^^^\n";
	
	my $request = decode_json( $line );

	if( ! defined $request->{operation} ){
		print "SyncDiff::DB->process_request() - No Operation specified!\n";
		print Dumper $request;
		return;
	}

##	print "SyncDiff::DB->process_request() - Operation: |". $request->{operation} ."|\n";

	if( $request->{operation} eq "new_transaction_id" ){
		return $self->_new_transaction_id( $request->{transaction_id} );
	}

	if( $request->{operation} eq "lookup_file" ){
		return $self->_lookup_file( $request->{filename}, $request->{group}, $request->{groupbase} );
	}

	if( $request->{operation} eq "getpwuid" ){
		return $self->_getpwuid( $request->{uid} );
	}

	if( $request->{operation} eq "getgrgid" ){
		return $self->_getgrgid( $request->{gid} );
	}
	if( $request->{operation} eq "add_file" ){
		return $self->_add_file( $request->{file} );
	}
	if( $request->{operation} eq "update_file" ){
		return $self->_update_file( $request->{file} );
	}

} # end process_request()

sub create_database {
	my( $self ) = @_;
	my $dbh = $self->dbh;

	$dbh->do("CREATE TABLE if not exists files (id INTEGER PRIMARY KEY AUTOINCREMENT, filepath TEXT, syncgroup TEXT, syncbase TEXT, filetype TEXT, inode_num INTEGER, perms INTEGER, uid INTEGER, username TEXT, gid INTEGER, groupname TEXT, size_bytes INTEGER, mtime INTEGER, extattr TEXT, checksum TEXT, deletestatus TEXT, last_transaction TEXT)");

	$dbh->do("CREATE TABLE if not exists transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, transactionid TEXT, group TEXT, timeadded INTEGER)");
} # end create_database()

sub send_request {
	my( $self, %request ) = @_;

##	print "SyncDiff::DB->send_request() - Starting\n";
	my $json = encode_json( \%request );

	my $db_pipe = $self->CHILD_IPC;

##	print Dumper $db_pipe;

	print $db_pipe $json ."\n";

##	print "We sent the thing off, waiting for return\n";

	my $line = undef;

	while( $line = <$db_pipe> ){
		if( defined $line  ){
			chomp( $line );
			last if( $line ne "" );
		}
	}

##	print Dumper $line;

	chomp( $line );

##	print "Got response\n";

##	print "*** DB->send_request() - return line:\n";
##	print Dumper $line;

	if( $line eq "0" ){
		return 0;
	}

	my $response = decode_json( $line );

	if( defined $response->{ZERO} ){
		return 0;
	}

	if( defined $response->{SCALAR} ){
		return $response->{SCALAR};
	}

	return $response;
}

sub new_transaction_id {
	my( $self, $transaction_id ) = @_;

##	print "SyncDiff::DB->new_transaction_id() - Starting\n";

	my %request = (
		operation	=> 'new_transaction_id',
		transaction_id	=> $transaction_id,
		);

	return $self->send_request( %request );
}

sub _new_transaction_id {
	my( $self, $transaction_id ) = @_;
	my $dbh = $self->dbh;

##	print "~~~ Adding a transaction\n";

##	print Dumper $dbh;
##
##	print "^^^^^^^^^^^^^^^^^^^^^^^^^\n";

	my $add_transaction = $dbh->prepare("INSERT INTO transactions (transactionid, timeadded) VALUES( ?, strftime('%s','now') )");
	$add_transaction->execute( $transaction_id );

	return 0;
} # end _new_transaction_id()

sub lookup_file {
	my( $self, $filename, $group, $groupbase ) = @_;
##	print "SyncDiff::DB->new_transaction_id() - Starting\n";

	my %request = (
		operation	=> 'lookup_file',
		filename	=> $filename,
		group		=> $group,
		groupbase	=> $groupbase,
		);

	my $response = $self->send_request( %request );

##	print Dumper $response;

	return $response;
} #end lookup_file()

sub _lookup_file {
	my( $self, $filename, $group, $groupbase ) = @_;
	my $dbh = $self->dbh;

	my $lookup_file = $dbh->prepare("SELECT * FROM files WHERE filepath=? and syncgroup=? and syncbase=?");
	$lookup_file->execute( $filename, $group, $groupbase);

	if ( $lookup_file->err ){
#		die "ERROR! return code: ". $sth->err . " error msg: " . $sth->errstr . "\n";
	}

	my $row_ref = $lookup_file->fetchall_hashref('id');
	if( ( scalar ( keys %$row_ref ) ) == 0 ){
		return 0;
	}

	my $fileobj = SyncDiff::File->new( dbref => $self );

	$fileobj->parse_dbrow( $row_ref );

	my %return_hash = $fileobj->to_hash();

	return \%return_hash;
} # end _lookup_file()

sub getpwuid {
	my( $self, $uid ) = @_;
	my %request = (
		operation	=> 'getpwuid',
		uid		=> $uid,
		);

	my $response = $self->send_request( %request );

	return (
		$response->{username},
		$response->{u_pass},
		$response->{u_uid},
		$response->{u_gid},
		$response->{u_quota},
		$response->{u_comment},
		$response->{u_gcos},
		$response->{u_dir},
		$response->{u_shell},
		$response->{u_expire},
		);
} # end getpwuid()

sub _getpwuid {
	my( $self, $uid ) = @_;

	my(
		$username,
		$u_pass,
		$u_uid,
		$u_gid,
		$u_quota,
		$u_comment,
		$u_gcos,
		$u_dir,
		$u_shell,
		$u_expire
	) = CORE::getpwuid( $uid );

	my %response = (
		username	=> $username,
		u_pass		=> $u_pass,
		u_uid		=> $u_uid,
		u_gid		=> $u_gid,
		u_quota		=> $u_quota,
		u_comment	=> $u_comment,
		u_gcos		=> $u_gcos,
		u_dir		=> $u_dir,
		u_shell		=> $u_shell,
		u_expire	=> $u_expire,
		);

	return \%response;
} # end _getpwuid()

sub getgrgid {
	my( $self, $gid ) = @_;

	my %request = (
		operation	=> 'getgrgid',
		gid		=> $gid,
		);

	my $response = $self->send_request( %request );

	return (
		$response->{groupname},
		$response->{g_passwd},
		$response->{g_gid},
		$response->{g_members},
		);
} # end getgrgid()

sub _getgrgid {
	my( $self, $gid ) = @_;

	my(
		$groupname,
		$g_passwd,
		$g_gid,
		$g_members,
	) = CORE::getgrgid( $gid );

	my %response = (
		groupname	=> $groupname,
		g_passwd	=> $g_passwd,
		g_gid		=> $g_gid,
		g_members	=> $g_members,
		);

	return \%response;
} # end _getpwuid()

sub add_file {
	my( $self, $file ) = @_;

	my %file_hash = $file->to_hash();

##	print "File hash:\n";
##	print Dumper \%file_hash;

	my %request = (
		operation	=> 'add_file',
		file		=> \%file_hash,
		);

	my $response = $self->send_request( %request );
} # end add_file()

sub _add_file {
	my( $self, $file ) = @_;
	my $dbh = $self->dbh;

##	print "------------------------\n";
##	print "DB->_add_file()\n";
##	print "------------------------\n";
##	print Dumper $file;
##	print "------------------------\n";

	my $file_obj = SyncDiff::File->new(dbref => $self );

	$file_obj->from_hash( $file );
##	print Dumper \$file_obj;
##	print "^^^^^^^^^^^^^^^^^^^^^^^^\n";

	my $new_file_sth =  $dbh->prepare("INSERT INTO files (filepath, syncgroup, syncbase, filetype, inode_num, perms, uid, username, gid, groupname, size_bytes, mtime, extattr, checksum, last_transaction) VALUES( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )");

	$new_file_sth->execute(
		$file_obj->filepath,
		$file_obj->syncgroup,
		$file_obj->syncbase,
		$file_obj->filetype,
		$file_obj->inode_num,
		$file_obj->mode,
		$file_obj->uid,
		$file_obj->username,
		$file_obj->gid,
		$file_obj->groupname,
		$file_obj->size_bytes,
		$file_obj->mtime,
		$file_obj->extattr,
		$file_obj->checksum,
		$file_obj->last_transaction
		);

	return 0;
} # end _add_file()

sub update_file {
	my( $self, $file ) = @_;

	my %file_hash = $file->to_hash();

	my %request = (
		operation	=> 'update_file',
		file		=> \%file_hash,
		);

	my $response = $self->send_request( %request );
} # end update_file()

sub _update_file {
	my( $self, $file ) = @_;
	my $dbh = $self->dbh;

	my $file_obj = SyncDiff::File->new(dbref => $self );

	$file_obj->from_hash( $file );

	my $new_file_sth =  $dbh->prepare("UPDATE files set filepath=?, syncgroup=?, syncbase=?, filetype=?, inode_num=?, perms=?, uid=?, username=?, gid=?, groupname=?, size_bytes=?, mtime=?, extattr=?, checksum=?, last_transaction=? WHERE filepath=? and syncgroup=? and syncbase=?");

	$new_file_sth->execute(
		$file_obj->filepath,
		$file_obj->syncgroup,
		$file_obj->syncbase,
		$file_obj->filetype,
		$file_obj->inode_num,
		$file_obj->mode,
		$file_obj->uid,
		$file_obj->username,
		$file_obj->gid,
		$file_obj->groupname,
		$file_obj->size_bytes,
		$file_obj->mtime,
		$file_obj->extattr,
		$file_obj->checksum,
		$file_obj->last_transaction,

		$file_obj->filepath,
		$file_obj->syncgroup,
		$file_obj->syncbase
		);

	return 0;
} # end _update_file()

sub update_last_seen_transaction {
	my( $self, $hostname, $group, $transactionid ) = @_;
	my $dbh = $self->dbh;
	
	my $update_transactions_seen = $dbh->prepare("replace into servers_seen (hostname, transactionid, group, timeadded) values ( ?, ?, ?, strftime('%s','now') )");
	$update_transactions_seen->execute( $hostname, $transactionid, $group );
} # end update_last_seen_transaction()

#no moose;
__PACKAGE__->meta->make_immutable;
#__PACKAGE__->meta->make_immutable(inline_constructor => 0,);

1;
