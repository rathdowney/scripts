#!/usr/bin/perl

# This script uses lists of MD5 hashes ('md5.db' files) to recursively
# keep track of changes in a directory.

# The script is multithreaded and keeps 1 thread for reading files into
# RAM, and a number of threads (based on CPU count) to process the
# files.

# Mechanical drives are slow, while RAM is much faster, so the reason
# for processing the files this way is to maximize performance. It
# guarantees that the hard drive only has to read 1 file at a time, even
# though multiple files will be processed at a time.

# File systems like Btrfs or ZFS already have checksumming built in.
# This script is meant for file systems that lack that capability.

# The script checks FLAC files using 'flac' and 'metaflac', so if you
# don't have those commands installed, only non-FLAC files will be
# checked.

use 5.34.0;
use strict;
use warnings;
use Cwd qw(abs_path cwd);
use Digest::MD5 qw(md5_hex);
use IO::Handle qw(autoflush);
use File::Basename qw(basename dirname);
use diagnostics;

use threads qw(yield);
use threads::shared;
use Thread::Queue;
use Thread::Semaphore;
use POSIX qw(SIGINT);

# Create the thread queue.
my $q = Thread::Queue->new();

# Get the number of available CPU cores. Add 1 to this number, which
# will lead to an extra thread being created, maximizing performance.
chomp(my $cores = `grep -c '^processor' /proc/cpuinfo`);
$cores++;

# Check if the necessary commands are installed to test FLAC files.
chomp(my @flac_req = ( `command -v flac metaflac 2>&-` ));

my(@lib, $mode);

# Path to and name of log file to be used for logging.
my $logf = $ENV{HOME} . '/' . 'md5db.log';

# Regex used for skipping dot files and directories in home directories.
my $dotskip = qr(^/home/[[:alnum:]]+/\.);

# Delimiter used for database.
my $delim = "\t\*\t";

# Array for storing the actual arguments used by the script internally.
# Might be useful for debugging.
my @cmd = (basename($0));

# Name of database file.
my $db = 'md5.db';

# Clear screen command.
my $clear = `clear && echo`;

# Creating a few shared variables.
# * %err will be used for errors.
# * $n will store the number of files that have been processed.
# * %files is the files hash.
# * @md5dbs is the md5.db array.
# * %md5h is the database hash.
# * %file_contents will store the contents of files.
# * $stopping will be used to stop the threads.
# * $file_stack will track the amount of file data currently in RAM.
# * $busy will be used to pause other threads when a thread is busy.
# * %gone will store the names and hashes of possibly deleted files.
# * %large will store the names of files that are too big to fit in RAM.
my %err :shared;
my $n :shared = 0;
my %files :shared;
my @md5dbs :shared;
my %md5h :shared;
my %file_contents :shared;
my $stopping :shared = 0;
my $file_stack :shared = 0;
my $busy :shared = 0;
my %gone :shared;
my %large :shared;

# Creating a variable which sets a limit on the total number of bytes
# that can be read into RAM at once. If you have plenty of RAM, it's
# safe to increase this number. It will improve performance.
my $disk_size = 1000000000;

# This will be used to control access to the logger subroutine.
my $semaphore = Thread::Semaphore->new();

# Creating a custom POSIX signal handler. First we create a shared
# variable that will work as a SIGINT switch. Then we define the handler
# subroutine.
POSIX::sigaction(SIGINT, POSIX::SigAction->new(\&handler))
or die "Error setting SIGINT handler: $!";
my $saw_sigint :shared = 0;

sub handler {
	{ lock($saw_sigint);
	$saw_sigint = 1; }

	{ lock($stopping);
	$stopping = 1; }
}

# Open file handle for the log file
open(my $LOG, '>>', $logf) or die "Can't open '$logf': $!";

# Make the $LOG file handle unbuffered for instant logging.
$LOG->autoflush(1);

# Duplicate STDOUT and STDERR as a regular file handles.
open(my $STDOUT, ">&STDOUT") or die "Can't duplicate STDOUT: $!";
open(my $STDERR, ">&STDERR") or die "Can't duplicate STDERR: $!";

# Subroutine for printing usage instructions.
sub usage {
	say "
Usage: $cmd[0] [options] [directory 1] .. [directory N]

	-help Print this help message.

	-double Check database for files that have identical
	hashes.

	-import Import MD5 sums to the database from already existing
	\*.MD5 files in each directory.

	-index Index new files in each directory.

	-test Test the MD5 sums of the files in the database to see if
	they've changed.
";

	exit;
}

# This loop goes through the argument list as passed to the script
# by the user when ran.
foreach my $arg (@ARGV) {
# If argument starts with a dash '-', interpret it as an option.
	if ($arg =~ /^-/) {
		given ($arg) {
# When '-double', set script mode to 'double', and call the md5double
# subroutine later.
			when (/^-double$/) {
				if (! length($mode)) { push(@cmd, $arg); $mode = 'double'; }
			}

# When '-import', set script mode to 'import', and call the md5import
# subroutine later.
			when (/^-import$/) {
				if (! length($mode)) { push(@cmd, $arg); $mode = 'import'; }
			}

# When '-help', set script mode to 'help', and print usage instructions
# later.
			when (/^-help$/) {
				if (! length($mode)) { push(@cmd, $arg); $mode = 'help'; }
			}

# When '-index', set script mode to 'index', and call the md5index
# subroutine later.
			when (/^-index$/) {
				if (! length($mode)) { push(@cmd, $arg); $mode = 'index'; }
			}

# When '-test', set the script mode to 'test', and call the md5test
# subroutine later.
			when (/^-test$/) {
				if (! length($mode)) { push(@cmd, $arg); $mode = 'test'; }
			}
		}
# If argument is a directory, include it in the @lib array.
	} else {
		if (-d $arg) {
			my $dn = abs_path($arg);
			push(@lib, $dn);
			push(@cmd, $dn);
		}
	}
}

# If no switches were used, print usage instructions.
if (! scalar(@lib) or ! length($mode) or $mode eq 'help') { usage(); }

# Subroutine for putting files in the queue, and loading them into RAM.
sub files2queue {
	my($files_ref);

	if ($mode eq 'index') {
		$files_ref = \%files;

# If file name already exists in the database hash, skip it.
		foreach my $fn (keys(%md5h)) {
			if (length($files{$fn})) { delete($files{$fn}); }
		}

# If file is a FLAC file, then enqueue it directly instead of reading it
# into RAM.
		foreach my $fn (keys(%files)) {
			if ($fn =~ /.flac$/i) {
				delete($files{$fn});
				$q->enqueue($fn);
			}
		}
	}

	if ($mode eq 'test') { $files_ref = \%md5h; }

	foreach my $fn (sort(keys(%{$files_ref}))) {
		my $size = (stat($fn))[7];

		if (! length($size)) { next; }

		if ($size <= $disk_size) {
			my $free = $disk_size - $file_stack;

			while ($size > $free) {
				yield();
				$free = $disk_size - $file_stack;
			}

			open(my $read_fn, '< :raw', $fn) or die "Can't open '$fn': $!";
			sysread($read_fn, $file_contents{$fn}, $size);
			close($read_fn) or die "Can't close '$fn': $!";

			{ lock($file_stack);
			$file_stack += length($file_contents{$fn}); }

			$q->enqueue($fn);
		} else { $large{$fn} = 1; }
	}

# Put all the large files in the queue, after all the smaller files are
# done being processed. This is to prevent multiple files from being
# read from the hard drive at once, slowing things down.
	if (keys(%large)) {
		while ($file_stack > 0) {
			say $file_stack . ' > ' . '0';
			yield();
		}

		foreach my $fn (sort(keys(%large))) { $q->enqueue($fn); }
	}

# If there's still files in the queue left to be processed, and SIGINT
# has not been triggered, wait for the other threads to empty the queue.
	while ($q->pending() > 0 and ! $stopping) { yield(); }

# We're using this subroutine / thread to indicate to the other threads
# when to quit, since this is where we create the file queue.
	{ lock($stopping);
	$stopping = 1; }
}

# Subroutine for when the script needs to quit, either cause of being
# finished, or SIGINT has been triggered.
sub iquit {
	my $tid = threads->tid();

	while (! $stopping) { yield(); }

	yield();

	foreach my $thr (threads->list()) {
		my $tid_tmp = $thr->tid();
		if ($tid_tmp eq $tid) { next; }

		if ($saw_sigint) { $thr->detach(); }
		else { $thr->join(); }
	}

# Print missing files.
	p_gone();

# Print the hash to the database file and close the log.
	hash2file();
	logger('end', $n);

	return;
}

# Subroutine for controlling the log file.
# Applying a semaphore so multiple threads won't try to access it at
# once, just in case ;-)
# It takes 2 arguments:
# (1) switch
# (2) file name / number
sub logger {
	$semaphore->down();

	my $sw = shift;
	my($arg, @fn, $n);

# Creating an array to hold the filehandles used to print messages.
	my @OUTS = ($STDOUT, $LOG);

# Creating a variable to hold the current time.
	my $now = localtime(time);

# Array of accepted switches to this subroutine
	my @larg = qw{start gone corr diff end};

# Loop through all the arguments passed to this subroutine Perform
# checks that decide which variable the arguments are to be assigned to.
	while (@_) {
		$arg = shift;

# If $arg is a number assign it to $n, if it's a file add it to @fn.
		if ($sw eq 'end') { $n = $arg; }
		else { push(@fn, $arg); }
	}

	given ($sw) {
# When log is opened.
		when ('start') {
			say $LOG "
**** Logging started on $now ****

Running script in \'$mode\' mode on:

$fn[0]
";
		}
# When file has been deleted or moved.
		when ('gone') {
			$err{$fn[0]} = 'has been (re)moved.';
		}
# When file has been corrupted.
		when ('corr') {
			$err{$fn[0]} = 'has been corrupted.';
		}
# When file has been changed.
		when ('diff') {
			$err{$fn[0]} = 'doesn\'t match the hash in database.';
		}
# When done or interrupted, to close the log.
# If errors occurred print the %err hash.
# Either way, print number of files processed.
		when ('end') {
# When the script is interrupted by user pressing ^C, say so in both
# STDERR and the log.
			if ($saw_sigint) {
				$OUTS[0] = $STDERR;

				foreach my $OUT (@OUTS) {
					say $OUT 'Interrupted by user!' . "\n";
				}
			}

			if (! keys(%err)) {
				foreach my $OUT (@OUTS) {
					say $OUT 'Everything is OK!' . "\n";
				}
			} else {
				$OUTS[0] = $STDERR;

				foreach my $OUT (@OUTS) {
					say $OUT 'Errors occurred!' . "\n";
				}

				foreach my $fn (sort(keys(%err))) {
					foreach my $OUT (@OUTS) {
						say $OUT $fn . "\n\t" . $err{$fn} . "\n";
					}
				}
			}

			if (length($n)) {
				foreach my $OUT (@OUTS) {
					say $OUT $n . ' file(s) were tested.' . "\n";
				}
			}

			say $LOG '**** Logging ended on ' . $now . ' ****' . "\n";
			close $LOG or die "Can't close '$LOG': $!";
		}
	}

	$semaphore->up();
}

# Subroutine for reading a database file into the database hash.
# It takes 1 argument:
# (1) file name
sub file2hash {
	my $db = shift;
	my $dn = dirname($db);
	my($fn, $hash, @lines);

# The format string which is used for parsing the database file.
	my $format = qr/^(.*)\Q$delim\E([[:alnum:]]{32})$/;

# Open the database file and read it into the @lines array.
	open(my $md5db_in, '<', $db) or die "Can't open '$db': $!";
	foreach my $line (<$md5db_in>) {
		$line =~ s/(\r){0,}(\n){0,}$//g;
		push(@lines, $line);
	}
	close($md5db_in) or die "Can't close '$db': $!";

# Loop through all the lines in the database file and split them before
# storing in the database hash. Also, print each line to STDOUT for
# debug purposes.
	foreach my $line (@lines) {
# If current line matches the proper database file format, continue.
		if ($line =~ /$format/) {
# Split the line into relative file name and MD5 sum.
			$fn = $1;
			$hash = $2;

# Add the full path to the file name, unless it's the current directory.
			if ($dn ne '.') { $fn = $dn . '/' . $fn; }

# If $fn is a real file.
			if (-f $fn) {
# Unless file name already is in the database hash, print a message, add
# it to the hash.
				if (! length($md5h{$fn})) {
					$md5h{$fn} = $hash;
					say $fn . $delim . $hash;
# If file name is in the database hash but the MD5 sum found in the
# database doesn't match, print to the log. This will most likely only
# be the case for any extra databases that are found in the search path
# given to the script.
				} elsif ($md5h{$fn} ne $hash) {
					logger('diff', $fn);
				}
# If file name is not a real file, add $fn to %gone hash.
			} elsif (! -f $fn) {
				lock(%gone);
				$gone{${fn}} = $hash;
			}
		}
	}
}

# Subroutine for printing the database hash to the database file.
sub hash2file {
	my($md5db_out);

# If the database hash is empty, return from this function, to keep from
# overwriting the database file with nothing.
	if (! keys(%md5h)) { return; }

	open($md5db_out, '>', $db) or die "Can't open '$db': $!";
# Loops through all the keys in the database hash and prints the entries
# (divided by the $delim variable) to the database file.
	foreach my $fn (sort(keys(%md5h))) {
		say $md5db_out $fn . $delim . $md5h{$fn} . "\r";
	}
	close($md5db_out) or die "Can't close '$db': $!";
}

# Subroutine for initializing the database hash, and the files array.
# This subroutine returns references. This is the first subroutine that
# will be executed and all others depend upon it.
# It takes 1 argument:
# (1) directory name
sub init_hash {
	my $dn = shift;

# Get all the file names in the path.
	getfiles($dn);

# Import hashes from every database file found in the search path.
	if (scalar(@md5dbs)) {
		foreach my $db (@md5dbs) { file2hash($db); }
	}

# Clears the screen, thereby scrolling past the database file print.
	print $clear;
}

# Subroutine for when the database file is empty, or doesn't exist.
sub if_empty {
	if (! keys(%md5h)) {
		say "
No database file. Run the script in 'index' mode first
to index the files.
";

		{ lock($stopping);
		$stopping = 1; }

		yield();
	}
}

# Subroutine for finding all files inside the directory name passed to
# it.
# It takes 1 argument:
# (1) directory name
sub getfiles {
	my $dn = shift;
	my(@lines);

	open(my $find, '-|', 'find', $dn, '-type', 'f', '-name', '*', '-nowarn')
	or die "Can't run 'find': $!";
	chomp(@lines = (<$find>));
	close($find) or die "Can't close 'find': $!";

	foreach my $fn (@lines) {
# If the file name matches "$HOME/.*", then ignore it. Directories in
# the home-dir of a user are usually configuration files for the desktop
# and various applications. These files change often and will therefore
# clog the log file created by this script, making it hard to read.
		if ($fn =~ m($dotskip)) { next; }

# Using quotemeta operators here (\Q & \E) because Perl interprets the
# string as a regular expression when it's not.
		$fn =~ s(^\Q$dn\E/)();

		if (-f $fn) {
			my $bn = basename($fn);

			if ($bn ne $db) { $files{$fn} = 1; }
			elsif ($bn eq $db) { push(@md5dbs, $fn); }
		}
	}
}

# Subroutine for clearing files from RAM, once they've been processed.
# It takes 1 argument:
# (1) file name
sub clear_stack {
	my $fn = shift;

	{ lock($file_stack);
	$file_stack -= length($file_contents{$fn}); }

	{ lock(%file_contents);
	delete($file_contents{$fn}); }
}

# Subroutine for finding duplicate files, by checking the database hash.
sub md5double {
# Loop through the %md5h hash and save the checksums as keys in a new
# hash called %exists. Each of those keys will hold an anonymous array
# with the matching file names.
	my(%exists);

	foreach my $fn (keys(%md5h)) {
		my $hash = $md5h{$fn};
		push(@{$exists{${hash}}}, $fn);
	}

# Loop through the %exists hash and print files that are identical, if
# any.
	foreach my $hash (keys(%exists)) {
		if (scalar(@{$exists{${hash}}}) > 1) {
			say 'These files have the same hash (' . $hash . '):';
			foreach my $fn (@{$exists{${hash}}}) { say $fn; }
			say '';
		}
	}
}

# Subroutine for finding and parsing *.MD5 files, adding the hashes to
# the database hash and thereby also to the file.
# It takes 1 argument:
# (1) file name
sub md5import {
	my $md5fn = shift;
	my $dn = dirname($md5fn);

	my($fn, $hash, @lines);

# The format string which is used for parsing the *.MD5 files.
	my $format = qr/^([[:alnum:]]{32})\s\*(.*)$/;

# Open the *.MD5 file and read its contents to the @lines array.
	open(my $md5_in, '<', $md5fn) or die "Can't open '$md5fn': $!";
	foreach my $line (<$md5_in>) {
		$line =~ s/(\r){0,}(\n){0,}$//g;
		push(@lines, $line);
	}
	close($md5_in) or die "Can't close '$md5fn': $!";

# Loop to check that the format of the *.MD5 file really is correct
# before proceeding.
	foreach my $line (@lines) {
# If format string matches the line(s) in the *.MD5 file, continue.
		if ($line =~ /$format/) {
# Split the line into MD5 sum and relative file name.
			$hash = lc($1);
			$fn = basename($2);

# Add the full path to the file name, unless it's the current directory.
			if ($dn ne '.') { $fn = $dn . '/' . $fn; }

# If $fn is a real file.
			if (-f $fn) {
# Unless file name already is in the database hash, print a message, add
# it to the hash.
				if (! length($md5h{$fn})) {
					$md5h{$fn} = $hash;
					say $fn . ': done indexing';
# If file name is in database hash but the MD5 sum from the MD5 file
# doesn't match, print to the log.
				} elsif ($md5h{$fn} ne $hash) {
					logger('diff', $fn);
				}
# If file name is not a real file, add $fn to %gone hash.
			} elsif (! -f $fn) {
				lock(%gone);
				$gone{${fn}} = $hash;
			}
		}
	}
}

# Subroutine for getting the MD5 hash of a file.
# It takes 1 argument:
# (1) file name
sub md5sum {
	my $fn = shift;
	my($hash);

	if (! -r $fn) { return; }

	while ($busy) { yield(); }

# If the file name is a FLAC file, test it with 'flac'.
	if ($fn =~ /.flac$/i) {
		$hash = md5flac($fn);

		if ($mode eq 'test') { clear_stack($fn); }

		return $hash;
	}

	if ($large{$fn}) {
		lock($busy);
		$busy = 1;

		open(my $read_fn, '< :raw', $fn) or die "Can't open '$fn': $!";
		$hash = Digest::MD5->new->addfile($read_fn)->hexdigest;
		close($read_fn) or die "Can't close '$fn': $!";

		$busy = 0;
	} else {
		$hash = md5_hex($file_contents{$fn});

		clear_stack($fn);
	}

	return $hash;
}

# Subroutine to index the files (i.e. calculate and store the MD5 sums
# in the database hash).
sub md5index {
	my $tid = threads->tid();
	my($tmp_md5);

# Loop through the thread que.
	while ((my $fn = $q->dequeue_nb()) or ! $stopping) {
		if (! length($fn)) { yield(); next; }

		$tmp_md5 = md5sum($fn);
		if (! length($tmp_md5)) { next; }

		$md5h{$fn} = $tmp_md5;

		say $tid . ' ' . $fn . ': done indexing (' . $file_stack . ')';

		{ lock($n);
		$n++; }
	}
}

# Subroutine for testing if the MD5 sums in the database file are
# correct (i.e. have changed or not).
sub md5test {
	my $tid = threads->tid();
	my($tmp_md5, $old_md5, $new_md5);

# Loop through the thread queue.
	while ((my $fn = $q->dequeue_nb()) or ! $stopping) {
		if (! length($fn)) { yield(); next; }

		$tmp_md5 = md5sum($fn);
		if (! length($tmp_md5)) { next; }

		$new_md5 = $tmp_md5;
		$old_md5 = $md5h{$fn};

		say $tid . ' ' . $fn . ': done testing (' . $file_stack . ')';

# If the new MD5 sum doesn't match the one in the hash, and file doesn't
# already exist in the %err hash, log it and replace the old MD5 sum in
# the hash with the new one.
		if ($new_md5 ne $old_md5 and ! length($err{$fn})) {
			logger('diff', $fn);
			$md5h{$fn} = $new_md5;
		}

		{ lock($n);
		$n++; }
	}
}

# Subroutine for getting the MD5 hash of FLAC files by reading their
# metadata. If the mode is 'test', the FLAC files will also be tested.
# It takes 1 argument:
# (1) file name
sub md5flac {
	my $fn = shift;
	my($hash);

	if (! -r $fn) { return; }

	if (scalar(@flac_req) == 2) {
		chomp($hash = `metaflac --show-md5sum "$fn" 2>&-`);
		if ($? != 0 and $? != 2) { logger('corr', $fn); return; }

		if ($mode eq 'test') {
			open(my $flac_test, '|-', 'flac', '--totally-silent', '--test', '-')
			or die "Can't open 'flac': $!";
			print $flac_test $file_contents{$fn};
			close($flac_test);

			if ($? != 0 and $? != 2) { logger('corr', $fn); return; }
		}

		return $hash;
	}
}

# Subroutine for figuring out which files have gone missing. If still
# existing files have identical MD5 hashes to those that are in %gone,
# then those file names will not be printed. The idea is that certain
# files may just have been renamed, or duplicates exist. Only print the
# files that are actually gone.
sub p_gone {
# If %gone is empty, return from this subroutine.
	if (! keys(%gone)) { return; }

	my(%gone_tmp);

# Translates the %gone hash to the %gone_tmp hash / array. We need to do
# it in this complicated way because 'threads::shared' has no support
# for hashes within hashes and arrays within arrays. That's why the
# global variables are only simple arrays, and we translate them to a
# hash / array here (in this subroutine).
	foreach my $fn (keys(%gone)) {
		my $hash = $gone{${fn}};
		push(@{$gone_tmp{${hash}}}, $fn);
	}

# Loops through the %md5h hash and deletes every matching MD5 hash from
# the %gone_tmp hash / array.
	foreach my $fn (keys(%md5h)) {
		my $hash = ${md5h{${fn}}};

		if ($gone_tmp{${hash}}) { delete($gone_tmp{${hash}}); }
	}

# Logs all missing files.
	foreach my $hash (keys(%gone_tmp)) {
		foreach my $fn (@{$gone_tmp{${hash}}}) { logger('gone', $fn); }
	}
}

# The 'iquit' thread needs to be started first, as the script relies on
# it being the first element in the 'threads' array. If script mode is
# either 'index' or 'test', we'll start as many threads as the
# available number of CPUs. Unless script mode is either of those, don't
# start the 'files2queue' thread, as it's not needed. Also, note that
# 'files2queue' needs to be started after the database hash has been
# initialized. Otherwise it will have nothing to work with.
my(@run);

push(@run, \&iquit);

given ($mode) {
	when ('index') {
		push(@run, ((\&md5index) x $cores));
		push(@run, \&files2queue);
	}
	when ('test') {
		push(@run, ((\&md5test) x $cores));
		push(@run, \&files2queue);
	}
}

# This loop is where the actual action takes place (i.e. where all the
# subroutines get called from).
foreach my $dn (@lib) {
	my(@threads);

# Change into $dn.
	chdir($dn) or die "Can't change into '$dn': $!";

# Start logging.
	logger('start', $dn);

# Initialize the database hash, and the files hash.
	init_hash($dn);

	if ($mode ne 'import' and $mode ne 'index') { if_empty(); }

# Starting threads.
	foreach (@run) {
		push(@threads, threads->create($_));
	}

	given ($mode) {
# Find duplicate files in database.
		when ('double') {
			md5double();
		}
# Import *.MD5 files to database.
		when ('import') {
			foreach my $fn (sort(keys(%files))) {
				if ($fn =~ /.md5$/i) { md5import($fn); }
			}
		}
	}

# If script mode is not 'index' or 'test', set the $stopping variable
# here, so the script can quit.
	if ($mode ne 'index' and $mode ne 'test') {
		{ lock($stopping);
		$stopping = 1; }
	}

# Since the 'iquit' subroutine / thread is in charge of joining threads,
# and finishing things up, all we have to do here is to join the 'iquit'
# thread.
	my $thr_iquit = $threads[0];
	$thr_iquit->join();

# If SIGINT has been tripped, break this loop.
	if ($saw_sigint) { last; }

# Resets all the global / shared variables, making them ready for the
# next iteration of this loop. In case the user specified more than one
# directory as argument.
	%err = ();
	$n = 0;
	%files = ();
	@md5dbs = ();
	%md5h = ();
	%file_contents = ();
	$stopping = 0;
	$file_stack = 0;
	$busy = 0;
	%gone = ();
	%large = ();
}
