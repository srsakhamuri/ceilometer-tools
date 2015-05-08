#!/usr/bin/perl -w

# problems
#  pattern match for -i recognition/removal (in -test) not robust enough

# Copyright 2005-2014 Hewlett-Packard Development Company, LP
#
# colmux may be copied only under the terms of either the Artistic License
# or the GNU General Public License, which may be found in the source kit

# Debug Values
#    1 - print interesting stuff
#    2 - print more instersting stuff
#    4 - do NOT start collectl.  real handy for debugging collectl side
#    8 - replaced functionality with -noescape
#   16 - show selected hostname/addresses and exit
#   32 - echo chars received on STDIN
#   64 - echo comments from collectl.  useful when inserting debugging comments
#  128 - echo everything from collectl
#  256 - async double-buffering
#  512 - echo collectl version checking commands

# KNOWN PROBLEMS
#
# pdsh format is not handled correctly by csh and you will need to quote expressions
#
# The format of the process data may vary based on whether or not a system provides
# I/O stats as well.  If not all systems provide a consistent format, you will get
# some unaligned columns, the headers based on the first system configuration.
#
# Lustre FS and OST names can vary in width so if you're monitoring systems with 
# different name widths the columns won't line up.  However, since one typically
# wouldn't monitor mixed lustre environments at the same time, they should all be
# consistent in width, unlike netnames whose widths do and you may need to
# include --netopts w in your collectl command
#
# colmux will sort columns as numeric or string.  Numeric preserves sort order whereas
# string sorts will go by the leftmost digits, giving 10 a higher sort order than 9.
# If colmux sees a column that does contain a digit it will do a string sort.  This
# will affect any number fields, eg process priorities can also be RT

use File::Basename;
use Getopt::Long;
use IO::Socket;
use IO::Select;
use Net::Ping;
use Time::Local;
use strict 'vars';

use threads;
use threads::shared;
my @threadFailure:shared;
my $firstHostName:shared;
my $firstColVersion:shared;

# This construct allows us to run in playback mode w/o readkey
# being installed by explicitly declaring the 2 routines below.
my $readkeyFlag=(eval {require "Term/ReadKey.pm" or die}) ? 1 : 0;

# it was discovered that the threads::join doesn't work with earlier versions
my $threadsVersion=threads->VERSION;

# Make sure we flush buffers on print.
$|=1;

my $Collectl='/usr/bin/collectl';
my $Program='colmux';
my $Version='4.9.0';
my $Copyright='Copyright 2005-2014 Hewlett-Packard Development Company, L.P.';
my $License="colmux may be copied only under the terms of either the Artistic License\n";
$License.= "or the GNU General Public License, which may be found in the source kit";

my $Ping='/bin/ping';
my $ResizePath='/usr/bin/resize:/usr/X11R6/bin/resize';
my $Route='/sbin/route';
my $Ifconfig='/sbin/ifconfig';
my $Grep='/bin/grep';
my $DefPort=2655;

my $K=1024;
my $M=1024*1024;
my $G=1024*1024*1024;

my $ESC=sprintf("%c", 27);
my $Home=sprintf("%c[H", 27);     # top of display
my $Bol=sprintf("%c[99;0f", 27);  # beginning of current line
my $Clr=sprintf("%c[J", 27);      # clear to end of display
my $Clscr="$Home$Clr";            # clear screen
my $Cleol=sprintf("%c[K", 27);    # clear to end of line

my $bold=sprintf("%c[7m", 27);
my $noBold=sprintf("%c[0m", 27);
my $bell=sprintf("%c", 7);

my $pingTimeout=5;
my $hiResFlag=(eval {require "Time/HiRes.pm" or die}) ? 1 : 0;
error('this tool requires the perl-time-hires module')    if !$hiResFlag;


# Let's see if we can find resize
my $resize;
foreach my $bin (split/:/, $ResizePath)
{ $resize=$bin    if -e $bin; }

my $termHeight=24;
my $termWidth=80;
if (defined($resize))
{
  `$resize`=~/LINES.*?(\d+)/m;
  $termHeight=$1;
  `$resize`=~/COLUMNS.*?(\d+)/m;
  $termWidth=$1;
}

# This controls real-time, multi-line sorting.
my %sort;

# Don't use unless you know all collectl versions support it
my $timeout='';

# Default parameter settings.
my $address='';
my $age=2;
my $noboldFlag=0;
my $nosortFlag=0;
my $noEscapeFlag=0;
my $column=1;
my $cols='';
my $colwidth=6;
my $command='';
my $debug=0;
my $delay=0;
my $freezeFlag=0;
my $homeFlag=0;
my $hostFilter='';
my $hostFormat='';
my $hostWidth=8;
my $keepalive='';
my $nocheckFlag=0;
my $port=$DefPort;
my $negdataval;
my $nodataval=-1;
my $maxLines=$termHeight;
my $username='';
my $sudoFlag=0;
my $sshkey='';
my $colhelp;
my ($helpFlag,$verFlag)=(0,0);
my ($revFlag,$zeroFlag)=(0,0);
my ($colhelpFlag,$colnodetFlag,$testFlag,$colTotalFlag,$col1Flag, $colKFlag, $reachableFlag, $quietFlag)=(0,0,0,0,0,0,0,0,0);
my $colnoinstFlag=0;
my $colLogFlag=0;
my $colnodiv='';
my $finalCr=0;
my $retaddr='';

GetOptions("address=s"    =>\$address,
	   "age=i"        =>\$age,
	   "colbin=s"     =>\$Collectl,
           "colk!"        =>\$colKFlag,
	   "collog10!"    =>\$colLogFlag,
           "col1000!"     =>\$col1Flag,
           "column=s"     =>\$column,
           "cols=s"       =>\$cols,
	   "colhelp!"     =>\$colhelpFlag,
           "colnodet!"    =>\$colnodetFlag,
           "colnoinst!"   =>\$colnoinstFlag,
           "colnodiv=s"   =>\$colnodiv,
           "coltotal!"    =>\$colTotalFlag,
           "colwidth=i"   =>\$colwidth,
	   "command=s"    =>\$command,
	   "debug=i"      =>\$debug,
           "delay=s"      =>\$delay,
	   "finalcr!"     =>\$finalCr,
           "lines=i"      =>\$maxLines,
	   "help!"        =>\$helpFlag,
	   "homeFlag!"    =>\$homeFlag,
           "hostfilter=s" =>\$hostFilter,
           "hostformat=s" =>\$hostFormat,
           "hostwidth=i"  =>\$hostWidth,
	   "keepalive=i"  =>\$keepalive,
           "negdataval=i" =>\$negdataval,
           "nodataval=i"  =>\$nodataval,
           "nocheck!"     =>\$nocheckFlag,
	   "nobold!"      =>\$noboldFlag,
	   "noescape!"    =>\$noEscapeFlag,
	   "nosort!"      =>\$nosortFlag,
	   "port=i"       =>\$port,
	   "quiet!"       =>\$quietFlag,
           "reachable!"   =>\$reachableFlag,
	   "retaddr=s"    =>\$retaddr,
           "reverse!"     =>\$revFlag,
	   "sshkey=s"     =>\$sshkey,
	   "sudo!"        =>\$sudoFlag,
           "test!"        =>\$testFlag,
	   "timeout=i"    =>\$timeout,
	   "username=s"   =>\$username,
	   "version!"     =>\$verFlag,
	   "zero!"        =>\$zeroFlag,
	   ) or error("type -help for help");
help()        if $helpFlag;

if ($verFlag)
{
  my $readkeyVer=($readkeyFlag) ? 'V'.Term::ReadKey->VERSION : 'not installed';
  print "$Program: $Version (Term::ReadKey: $readkeyVer Threads: $threadsVersion)\n\n$Copyright\n$License\n";
  exit;
}

if ($noEscapeFlag)
{
  $readkeyFlag=0;
  $Home=$Bol=$Clr=$Clscr=$Cleol=$bold=$noBold=$bell='';
}

# This may evolve over time
my ($hostDelim, $hostPiece)=('','');
if ($hostFormat ne '')
{
  error('only valid format is char:pos')    if $hostFormat!~/^\S{1}:\d+$/;
  ($hostDelim, $hostPiece)=split(':', $hostFormat)
}

# if sudo mode
$Collectl="sudo $Collectl"    if $sudoFlag;

# ok if host not in known_hosts and when not debugging be sure to turn off motd
my $Ssh='/usr/bin/ssh -o StrictHostKeyChecking=no -o BatchMode=yes';
$Ssh.=" -o ServerAliveInterval=$keepalive"    if $keepalive ne '';
$Ssh.=" -q"    unless $debug;

error('-nocheck and -recheck are mutually exclusive')    if $nocheckFlag && $reachableFlag;
error('-nocheck and -quiet are mutually exclusive')      if $nocheckFlag && $quietFlag;

#    P a r s e    T h e    C o m m a n d

error('--top not allowed')    if $command=~/--top/;

# any imports?  we HAVE to deal with these before looking at -s because if there
# are and no -s, we have NO subsystems selected.  We need to count them and also
# set a flag if ANY of them have specifice a 'd' parameter
$command=~/--imp.*?\s+(\S+)/;
my $imports=(defined($1)) ? $1 : '';
my $numImports=0;
my $importDetail=0;
foreach my $import (split(/:/, $imports))
{
  $numImports++;

  # here'e where we check for a 'd'
  foreach my $param (split(/,/, $import))
  {
    if ($param=~/^[sd]+$/)
    {
      $importDetail=1    if $param=~/d/;          # see if detail data
      $numImports++      if length($param)==2;    # if both, we have 2 subsys, not 1
    }
  }
}

# default subsys depends on whether any imports
my $defSubsys=($imports ne '') ? '' : 'cdn';
my $subsys=($command=~/-s\s*(\S+)/) ? $1 : $defSubsys;

my $expFlag= ($command=~/--exp/) ? 1 : 0;
my $verbFlag=($command=~/--verb/) ? 1 : 0;
my $plotFlag=($command=~/-P/) ? 1 : 0;
my ($fromTime, $thruTime)=split(/-/, $1)    if $command=~/--fr\S*\s+(\S+)/;
$thruTime=$1                                if $command=~/--th\S*\s+(\S+)/;
#error("invalid from/thru time")             if !checkTime($fromTime) || !checkTime($thruTime);

# Get options from command string being sure to IGNORE hostname in playback mode which could
# contain within but removing all occurances of {char}-o from original command
my $temp=$command;
$temp=~s/\S-o//i;
my $options=($temp=~/-o\s*(\S+)/) ? $1 : '';

# get today's date as well as building one in the standard format if specified in command
# note - $year, $mon and $day must not be changed!
my ($date, $day, $mon, $year, $today, $yesterday);
($day, $mon, $year)=(localtime(time-86400))[3..5];
$yesterday=sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
($day, $mon, $year)=(localtime(time))[3..5];
$today=sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
$date=($options=~/d/) ? sprintf("%02d/%02d", $mon+1, $day) : sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
$command=~s/TODAY/*$today*/i;
$command=~s/YESTERDAY/*$yesterday*/i;

# Surrounding the command with spaces makes the parsing easier below.  We're looking
# for playback filenames and then surrounding them with "s
$command=" $command ";
my ($playbackFile, $playbackFlag);
error('-p in collectl command requires an argument')    if $command=~/-p\s+\-|--pla\S+\s+-/;
$playbackFile=$1    if $command=~s/\s-p\s*(\S+)(.*)/ -p "$1"$2/;
$playbackFile=$2    if $command=~s/\s(--pla.*?)\s+(\S+)(.*)/ $1 "$2"$3/;
$playbackFlag=(defined($playbackFile)) ? 1 : 0;
$command=~s/^ (.*) $/$1/;    # remove leading/trailing spaces

error('-P only allowed with -cols')                            if $plotFlag && $cols eq '' && !$testFlag;
error('-colnodiv only applies to -cols')                       if $colnodiv ne '' && $cols eq '';
error('only valid -o values are mndDT')                        if $options ne '' && $options!~/^[mndDT]+$/;
error('-o only allows 1 of dDT')                               if $options ne '' && $options=~/([dDT]+)/ && length($1)>1;
error('-om requires at least 1 of dDT')                        if $options eq 'm';
error('-hostfilter only applies to local playback files')      if $hostFilter ne '' && (!$playbackFlag || $address ne '');
error('-home only applies to multi-line playback data')        if $homeFlag && $cols eq '' && !$playbackFlag;
error('cannot mix slab/process data with anything else')       if $subsys=~/[YZ]/ && $subsys=~/[a-zA-X]/;

# real-time, multi-line default is -home
$homeFlag=1    if $cols eq '' && !$playbackFlag;

if (!$plotFlag)
{
  # how many subsys, including imports, are being reported?
  # note that if an uppercase subsys OR an import with a 'd', we have detail data present
  my $numSubsys=$numImports+(($subsys ne '-all') ? length($subsys) : 0);
  my $detailFlag=($subsys=~/^[A-X]+$/ || $importDetail) ? 1 : 0;
  error('--verbose not allowed with multiple subsystems w/o -P')        if $verbFlag && $numSubsys>1;
  error('cannot mix summary and detail data w/o -P')                    if $subsys=~/[a-x]/ && $subsys=~/[A-X]/;
  error('cannot specify detail data when multiple subsystems w/o -P')   if $numSubsys>1 && $detailFlag;
}

my $localFlag=1;
my (@hostnames, $firstAddress);
if (!$playbackFlag || $address ne '')
{
  $address='localhost'    if $address eq '';    # use 'localhost' for real-time mode
  $localFlag=0;
  if (-f $address)
  {
    open ADDR, "<$address" or die "Couldn't open '$address'";
    while (my $line=<ADDR>)
    {
      next    if $line=~/^#|^\s*$/;
      chomp $line;
      $line=~s/^\s*//;    # strip leading whitespace
      push @hostnames, $line;
    }
    close ADDR;
  }
  else
  {
    @hostnames=pdshFormat($address);
  }
}
my $numHosts=scalar(@hostnames);

# See if any host specs contain 'username@' & reset 'localhost' and
# adjust maximum hostname length if necessary.
my $hostlen=$hostWidth;
my $myhost=`hostname`;
chomp $myhost;

my (%usernames, %sshswitch, %aliases);
for (my $i=0; $i<@hostnames; $i++)
{
  # $hostnames[] is typically just the hostname, but sometimes it's more complex and in those cases
  # we need to pull out the optional ssh prefix, username and aliases.
  my $host=$hostnames[$i];

  # NOTE - to use sshswitches you MUST use @ as well so strip everything
  # preceding hostname and save host (ignoring alias if there is one)
  my ($prefix, $user, $alias)=('','','');
  if ($hostnames[$i]=~s/(.*)@(\S+)/$2/)
  {
    $user=$1;
    $host=$2;

    # if whitespace, the it's really a prefix and username
    if ($user=~/(.*)\s+(\S+)/)
    {
      $prefix=$1;
      $user=$2;
    }
    #print "PREFIX: $prefix USER: $user  HOST: $host\n";
  }
  error("-i and/or usernames in addr file conflict with -sshkey")    if $prefix ne '' && $sshkey ne '';

  if ($hostnames[$i]=~/(\S+)\s+(\S+)/)
  {
    $host=$1;
    $alias=$2;
    #print "ALIAS[$host]: $alias\n";
  }

  # if -username, initially associate it with ALL hosts
  $usernames{$host}=$username       if $username ne '';
  $usernames{$host}=$user           if $user ne '';
  $sshswitch{$host}=$prefix         if $prefix ne '';
  $sshswitch{$host}="-i $sshkey"    if $sshkey ne '';
  $aliases{$alias}=$i               if $alias ne '';

  # make sure this only contains a hostname
  $hostnames[$i]=$host;

  # force local hostname if 'localhost'
  $hostnames[$i]=$myhost         if $hostnames[$i] eq 'localhost';

  # determine the maximum host's name and if a real name vs an address, remove
  # the domain portion as well.
  my $tempname=$host;
  $tempname=(split(/\./, $tempname))[0]    if $tempname=~/^[a-z]/i;
  $hostlen=length($tempname)               if length($tempname)>$hostlen;
}

#########################################################################################
#    C h e c k    A l l    H o s t s    F o r    R e a c h a b i l i t y  /  C o n f i g
#########################################################################################

# make sure all remote hosts are reachable and properly configured
my @threads;
if ($address ne '' && !$nocheckFlag)
{
  # seems that even though a timeout of 1 second if long enough to detect failed pings,
  # we need longer or else good nodes will get failed trying to connect back to us
  my $ping=Net::Ping->new();
  for (my $i=0; $i<@hostnames; $i++)
  { $threads[$i]=threads->create('check', $i); }

  # Wait for ping responses in 10ths of a second
  for (my $i=0; $i<$pingTimeout*10; $i++)
  {
    last    if threadsDone($numHosts);
    Time::HiRes::usleep(100000);
  }

  # Finally go back through hosts list in reverse order so we don't shift things
  # on top of each other, removing any that report unsuitability for use
  my $killSsh=0;
  my $allReachableFlag=1;
  my $printedReturnFlag=0;
  for (my $i=@hostnames-1; $i>=0; $i--)
  {
    if ($threadFailure[$i])
    {
      $allReachableFlag=0;

      # If ping failed, thread already gone but if ssh it's still there so we need to kill
      # the ssh.  Set a flag so we can do them all at once.
      $killSsh=1    if $threadFailure[$i]==-1;

      print "\n"    if !$printedReturnFlag;    # because ssh failures doesn't return carriage

      my $reason;
      $reason='passwordless ssh failed'            if $threadFailure[$i]==-1;
      $reason='ping failed'                        if $threadFailure[$i]==1;
      $reason='collectl not installed'             if $threadFailure[$i]==2;
      $reason='connection refused'                 if $threadFailure[$i]==4;
      $reason='permission denied'                  if $threadFailure[$i]==8;
      $reason='could not resolve name'             if $threadFailure[$i]==16;
      $reason='timed out during banner exchange'   if $threadFailure[$i]==32;
      $reason='collectl version < 3.5'             if $threadFailure[$i]==64;

      printf "$hostnames[$i] removed from list: $reason\n";
      $printedReturnFlag=1;
      splice(@hostnames, $i, 1);
      $numHosts--;
    }
  }

  if ($killSsh)
  {
    # We need to look for a ps command w/o the -q
    my $tempSsh=$Ssh;
    $tempSsh=~s/ -q//;

    print "Killing hung ssh(s)\n"    if $debug & 1;
    open PS, "ps axo pid,command|" or error("couldn't execute 'ps' to find ssh processes");
    while (my $line=<PS>)
    {
      next    if $line!~/$tempSsh/;

      $line=~s/^\s+//;    # can have leading space
      my $pid=(split(/\s+/, $line))[0];
      print "Killing ssh with pid: $pid\n"    if $debug & 1;
      `kill $pid`;
    }
    sleep 1;    # wait a tad for ssh in thread to exit
    close PS;
  }

  # for newer threads versions, all must be joined or we'll get errors when we exit
  if ($threadsVersion>'1.59')
  {
    foreach my $thread (threads->list(threads::joinable))
    { $thread->join(); }
  }

  # if nobody reachable!
  error('no accessible addresses in list')    if !$numHosts;

  # a couple of reasons to exit, but only report message if due to
  # unreachability
  if (!$allReachableFlag && $reachableFlag)
  {
    Term::ReadKey::ReadMode(0)    if $readkeyFlag;
    print "Not all hosts configured correctly or reachable and so exiting...\n";
    exit;
  }
}

if ($debug & 16)
{
  # the print is over-the-top, but IS useful for verifying usernames parsed correctly
  print ">>> addresses <<<\n";
  printf "%-${hostlen}s  %s\n", 'HOST', 'USERNAME';
  for (my $i=0; $i<$numHosts; $i++)
  { printf "%-${hostlen}s  %s\n", $hostnames[$i], defined($usernames{$hostnames[$i]}) ? $usernames{$hostnames[$i]} : ''; }
  exit;
}

###############################
#    C o m m o n    S t u f f
###############################

error('-lines cannot be negative')    if $maxLines<0;

# Makes a little easier to reference later.
my $timeFlag=($options=~/[dDT]+/) ? 1 : 0;

# These switches are common to both real-time and playback modes, but
# some of those mode-specific switches not allowed in this mode.
my @columns;
my $maxColNum=0;
my $maxDataAge;
my $interval=($command=~/-i\s*:*(\d+)/) ? $1 : 1;    # tricky because of --import
my @colsNoDiv;
if ($cols ne '')
{
  # make sure all data numeric
  $command.=' -w';

  # any data older than this is consider invalid, noting if secondary interval
  # just use 1.
  my $ageInterval=($interval=~/:/) ? 1 : $interval;
  $maxDataAge=$age*$ageInterval;

  # We need to set this first so -test will work right
  @columns=split(/,/,$cols);

  # Skip ALL cols related validation with -test
  if (!$testFlag)
  {

    error('-nosort not allowed in column mode')               if $nosortFlag;
    error('-delay not allowed in column mode unless -p')      if $delay && !$playbackFlag;
    error('-colnodet requires -coltotal')                     if $colnodetFlag && !$colTotalFlag;
    error('detailed data not allowed unless -P')              if $subsys=~/[A-X]/ && !$plotFlag;

    foreach my $col (@columns)
    {
      error('you cannot select host column with -cols, verify with -test')    if $col==0;
      error('-cols incorrectly specifies date/time field.  verify with --test')
	  if ($col==1 && $timeFlag) || ($col==2 && $options=~/[dD]/) || ($col<3 && $plotFlag);
      $maxColNum=$col    if $col>$maxColNum;
    }
  }

  if ($colnodiv ne '')
  {
    my @cols=split(/,/, $colnodiv);
    foreach my $col (@cols)
    {
      error("non-numeric column in -colnodiv: $col")    if $col!~/^\d+$/;
      my $match=0;
      for my $i (@columns)
      { $match=1    if $col==$i; }
      error("specified column $col with -colnodiv but not with -cols")    if !$match;
      $colsNoDiv[$col]=1;
    }
  }
}
else
{
  error('-colk only applies to -columns')                     if $colKFlag;
  error('-collog only applies to -columns')                   if $colLogFlag;
  error('-col1000 only applies to -columns')                  if $col1Flag;
  error('-colnodet only applies to -columns')                 if $colnodetFlag;
  error('-coltotal only applies to -columns')                 if $colTotalFlag;
  error('-nodataval only applies to -columns')                if $nodataval!=-1;
  error('-negdataval only applies to -columns')               if defined($negdataval);
  error("-o not allowed for 'real-time', non-cols format")    if !$playbackFlag && $timeFlag;
}

# force -oT if time not specified by either appending to command OR adding
# to -o if that has been specified
if (!$timeFlag)
{
  $command=~s/-o/-oT/    if $options ne '';
  $command.=' -oT'       if $options eq '';
}

# Additional globals, may only be needed by one mode
my $input;
my $ctrlCFlag=0;
my $numCols=0;
my $numLines=-1;
my $numReporting=0;
my $somethingPrintedFlag;
my $boldFlag=($noboldFlag) ? 0 : 1;
my $oldColFlag;
my (@printStack, @hostdata);
my (@host, @hostVars, @sample, %files);

# if in 'local' mode we don't yet know the max host name length for reformHeaders()
# so get it here first and while we're at is save the hostnames for later too
if ($playbackFlag && $localFlag)
{
  my (%temp, $host);
  my @hostFilters=pdshFormat($hostFilter)    if $hostFilter ne '';

  my $globSpec=$playbackFile;
  $numHosts=0;
  $globSpec=~s/"//g;
  foreach my $file (glob($globSpec))
  {
    # When we glob, we expand the string as would the shell.  If no wildards it just
    # returns itself which may NOT be a valid filename so we have to test
    next    if !-f $file;
    next    if $file!~/\d{8}-\d{6}\.raw/;

    $file=basename($file);
    $file=~/(.*)-\d{8}-\d{6}\.raw/;
    $host=$1;
    next    if defined($temp{$host});    # if already seen/kept this hostname

    # if using host filters, only identify keep those that match
    if ($hostFilter ne '')
    {
      my $filterMatch=0;
      foreach my $filter (@hostFilters)
      { $filterMatch=1    if $filter eq $host; }
      next    if !$filterMatch;
    }

    # keep this host and add ONCE to list of hosts to be processed
    $numHosts++;
    $temp{$host}='';
    push @hostnames, $host;
    $hostlen=length($host)    if $hostlen<length($host);
  }
  error('no files match playback file specification')    if scalar(@hostnames)==0;
}

# build command to get headers noting in real-time mode
my (@headers, @headernames, @headerPos);
my $switch=(!defined($sshswitch{$hostnames[0]})) ? '' : $sshswitch{$hostnames[0]};
my $uname= (!defined($usernames{$hostnames[0]})) ? '' : "$usernames{$hostnames[0]}\@"    if !$localFlag;
my $access=($localFlag) ? "$Ssh -n $myhost" : "$Ssh -n $switch $uname$hostnames[0]";
@headers=getHeaders($access, $command);

# get last header line
my $gotHeadersFlag=(defined($headers[0])) ? 1 : 0;
print "GotHeader: $gotHeadersFlag\n"       if $debug & 1;

my $lastHeader=$headers[-1];
if ($gotHeadersFlag)
{
  exit    if !reformatHeaders();

  print "LASTHEADER: $lastHeader\n";
  foreach my $col (split(/\s+/, $lastHeader))
  {
    # strip detail field names including surrounding []s
    $col=~s/\[.*\]//    if $colnoinstFlag;
    print "PUSH: $col\n";
    push @headernames, $col;
  }
}

# need room for headers and possible help line for JD
my $bodyLines=$maxLines-scalar(@headers);
$bodyLines--    if $colhelpFlag;

if ($testFlag)
{
  showHeaders();
  Term::ReadKey::ReadMode(0)    if $readkeyFlag;
  exit;
}

# if readkey there, change terminal characteristics to handle raw
# mode as well as disabling echo
Term::ReadKey::ReadMode(4)    if $readkeyFlag;

#################################
#    R e a l t i m e    M o d e
#################################

# this global give stdin() visibility into how many lines of output are available
my $totalLines;

my $startLine=1;
if (!$playbackFlag)
{
  error('-nosort only applies to playback mode')          if $nosortFlag;
  error('--from/--thru not allowed in real-time mode')    if defined($fromTime) || defined($thruTime);
  error('-delay only applies to playback mode')           if $delay;

  # never in single line format.
  $homeFlag=0    if $cols ne '';

  # Pull out addresses from address file (or list or whatever form
  # these came to us in.
  my (%hostNumMap, %addrhost);
  for (my $i=0; $i<$numHosts; $i++)
  {
    # Could be an address OR a simply host name
    my $host=$hostnames[$i];
    my $gbn=gethostbyname($host);
    error("cannot resolve '$host' to a network address")    if !defined($gbn) || $gbn eq '';
    my $netaddr=inet_ntoa(scalar($gbn));
    error("'$host' resolves to 127.0.0.1!  use a different host")    if $netaddr eq '127.0.0.1';

    $addrhost{$netaddr}=$i;
    $firstAddress=$netaddr    if !defined($firstAddress);

    $hostVars[$i]->{bufptr}=0;
    $hostVars[$i]->{maxinst}->[0]=-1; $hostVars[$i]->{lastinst}->[0]=-1; $hostVars[$i]->{lasttime}->[0]='';
    $hostVars[$i]->{maxinst}->[1]=-1; $hostVars[$i]->{lastinst}->[1]=-1; $hostVars[$i]->{lasttime}->[1]='';
  }

  #    O p e n   O u r    S o c k e t ( s )

  my $myReturnAddr=($retaddr eq '') ? getReturnAddress($firstAddress) : $retaddr;
  my $mySocket = new IO::Socket::INET(Type=>SOCK_STREAM,
                               Reuse=>1, Listen => 1,
                               LocalPort => $port)
      or error("couldn't create local socket on port: $port");

  my $sel = new IO::Select($mySocket);
  print "Listening for connections on $port\n"    if $debug & 1;

  #    S e t    A l a r m

  # if interval specified in command, use that; otherwise 1
  my $interval=(defined($interval)) ? $interval : 1;
  $interval=~s/.*://;    # In case sub-intervals
  $SIG{"ALRM"}=\&alarm;
  my $uInterval=$interval*10**6;
  Time::HiRes::ualarm($uInterval, $uInterval);

  #    S t a r t    R e m o t e    c o l l e c t l s

  for (my $i=0; $i<$numHosts; $i++)
  {
    my $switch=(!defined($sshswitch{$hostnames[$i]})) ? '' : $sshswitch{$hostnames[$i]};
    my $uname= (!defined($usernames{$hostnames[$i]})) ? '' : "$usernames{$hostnames[$i]}\@";
    my $access=($localFlag) ? '$Ssh -n localhost' : "$Ssh -n $switch $uname$hostnames[$i]";

    # MUST include timestamps
    my $colCommand= "$access $Collectl $command -A $myReturnAddr:$port";
    $colCommand.=":$timeout"        if $timeout ne '';
    $colCommand.=" --quiet"         if !$debug;
    $colCommand.=" &";

    print "Command: $colCommand\n"    if $debug & 1;
    system($colCommand)               unless $debug & 4;
  }

  # start with a clear screen
  print "$Home$Clscr"    if $homeFlag;

  # add STDIN to list of handles to look for input on.
  $sel->add(STDIN);

  my $Record='';
  my $hostNum=0;
  my $headerHost=-1;
  my $lastHost=-1;
  my ($remoteAddr, %sockHandle);
  while(!$ctrlCFlag)
  {
    # NOTE  - since much of collectl's multiline prints are via multiple socket
    #         writes, the data may come back as separate lines here, and not
    #         necessary all together so we need to track the last one seen
    # NOTE2 - the can_read() below will prematurely wake up when the timer goes
    #         off but that's ok because it will simply fall through the loop and
    #         come right back...
    while(my @ready = $sel->can_read(1))
    {
      foreach my $filehandle (@ready)
      {
        if ($filehandle eq 'STDIN')
	{
	  stdin();
          next;
        }

        # NOTE - logic for handling hosts by socket stolen from colgui
	if ($filehandle==$mySocket)
	{
	  # Create a new socket
	  my $new = $mySocket->accept;
	  $remoteAddr=inet_ntoa((sockaddr_in(getpeername($new)))[1]);
	  $sockHandle{$new}=$addrhost{$remoteAddr};
	  $sockHandle{$new}=(defined($addrhost{$remoteAddr})) ? $addrhost{$remoteAddr} : $aliases{$remoteAddr};
	  $sel->add($new);

	  # if we do get a connection from an unexpected place, accept it in case we
	  # keep getting it, but then ignore it!
	  if (!defined($addrhost{$remoteAddr}))
	  {
	    print "*** connection from unknown source: $remoteAddr! ***\n"    unless $quietFlag;
	    next;
	  }

	  printf "New socket connection from Host: %d Addr: %s\n",
                $sockHandle{$new}, $remoteAddr
                    if $debug & 1;
	  $numReporting++;
        }
	else
	{
	  my ($host, $time, $therest);
	  $Record=<$filehandle>;

	  if ($Record)
	  {
	    chomp $Record;
	    print ">>> $Record\n"    if $debug & 128;

  	    ($host, $therest)=split(/ /, $Record, 2);  # preserve leading spaces in 'therest'
	    $hostNum=$sockHandle{$filehandle};

	    if (!defined($hostNum))
	    {
	      print "Ignoring records from '$host' which is not ";
              print "recognizable.  Is the alias wrong or missing?\n";

  	      $remoteAddr=inet_ntoa((sockaddr_in(getpeername($filehandle)))[1]);
	      $sel->remove($filehandle);
	      $filehandle->close;
	      $numReporting--;
	      next;
	    }

	    $hostNumMap{$filehandle}=$hostNum;
	    $host[$hostNum]=($hostFormat eq '') ? $host : (split(/$hostDelim/, $host))[$hostPiece];
	    if ($therest=~/^#/)
	    {
    	      print "$therest\n"    if $debug & 64;

              # when first starting up, not all hosts necessarily respond during initial
	      # cycle so let's save the header from the first one who does
	      next    if ($gotHeadersFlag || ($headerHost!=-1 && $headerHost!=$hostNum));

              # We want to skip the first line of the process data header
	      next    if $therest=~/^###/ && $subsys=~/Z/;

	      $headerHost=$hostNum;
	      push @headers, $therest    if !$gotHeadersFlag;
	      #print "HostNum: $hostNum TheRest: $therest\n";
	    }
	    else
	    {
              # Once we see data from the host we got the header from, we're done setting it.
              # but if an error with -cols (only discoverable at this point with older collectls)
              # treat as a ^C.
              next            if $therest eq '';
	      if (!$gotHeadersFlag && $headerHost==$hostNum && scalar(@headers))
              {
   	        $gotHeadersFlag=1;
		$ctrlCFlag=1    if !reformatHeaders();
	      }

	      # Typically the data piece contains a timestamp as first  field, but if date is
	      # requested to be displayed as well we'll pull the time out of the first field
	      # in '$therest', later on.  But if it IS plot format we always start with date/time
	      if (!$plotFlag)
	      { 
		($time, $therest)=split(/ /, $therest, 2);
	      }
	      else
	      {
		($date, $time, $therest)=split(/ /, $therest, 3);
	      }
	      
              # since we know the instance of the last entry stored for this host, we now want the next one
	      # however, if the times have changed we need to reset to 0 since this is all new data.  Also need
              # to reset 'maxinst' to make sure we don't include any stale data which may also be in different
	      # positions.
              my $bufptr=$hostVars[$hostNum]->{bufptr};
	      my $index=$hostVars[$hostNum]->{lastinst}->[$bufptr]+1;
	      #print "BUFPTR: $bufptr  INDEX: $index  TIME: $time  LTIME: $hostVars[$hostNum]->{lasttime}->[$bufptr]\n";
	      if ($time ne $hostVars[$hostNum]->{lasttime}->[$bufptr])
	      {
		 $bufptr=($bufptr+1) % 2;
		 $hostVars[$hostNum]->{bufptr}=$bufptr;
		 $index=$hostVars[$hostNum]->{maxinst}->[$bufptr]=0;
	      }
	      $lastHost=$hostNum;
	      $hostVars[$hostNum]->{lasttime}->[$bufptr]=($plotFlag || $options!~/[dD]/) ? $time : (split(/\s+/, $therest))[0];

              # Be sure to update sample BEFORE updating pointers
	      my $key=(split(/\s+/, $therest))[0];
	      $sample[$hostNum]->[$index]->[$bufptr]=($plotFlag || $timeFlag) ? "$time $therest": $therest;
	      #print "SAMPLE[$hostNum][$index][$bufptr]: $sample[$hostNum]->[$index]->[$bufptr]\n";

              # when doing plot mode we always reconstruct the original record as we also do in non-plot
              # mode when the user specifies a time format option.  Remember, the ONLY time options can
              # be set are in cols mode so that's why we don't have to add that to the test below.
	      $hostVars[$hostNum]->{lastinst}->[$bufptr]=$index;
	      $hostVars[$hostNum]->{maxinst}->[$bufptr]=$index    if $index>$hostVars[$hostNum]->{maxinst}->[$bufptr];

	      print "B Host[$hostNum]: $host BUF: $bufptr MAXINST: $hostVars[$hostNum]->{maxinst}->[$bufptr] ".
		    "LASTINST: $hostVars[$hostNum]->{lastinst}->[$bufptr] TIME: $time LASTTIME: ".
		    "$hostVars[$hostNum]->{lasttime}->[$bufptr] KEY: $key\n"    if $debug & 256
	    }
	    next;
          }

	  # Sending socket must have gone away so clean it up
	  $remoteAddr=inet_ntoa((sockaddr_in(getpeername($filehandle)))[1]);
	  $sel->remove($filehandle);
	  $filehandle->close;

	  $numReporting--;

	  printf "Disconnected host #$hostNumMap{$filehandle}: $remoteAddr. %d remaining\n", $numReporting
	    if $debug & 1;

          # Remove this address from @host which probably should have been built from $remoteAddr
          # rather than name in record returned by collectl, but it's too late now
	  delete $host[$hostNumMap{$filehandle}];

	  # when all sockets have been closed, time to exit
          if ($numReporting==0 && !($debug & 4))
          {
            $ctrlCFlag=1;
	    last;
	  }
        }
      }
    }
  }
  $mySocket->close();

  # this probably isn't necessary but just to be sure all the ssh sessions are dead,
  # kill them off, noting since multiple ones would have to have unique ports, there
  # is no danger of killing the wrong ones.
  open PS, "ps axo pid,command|";
  while (my $line=<PS>)
  {
    next    if $line!~/$myReturnAddr:$port/;

    # pid can have leading spaces
    $line=~s/^\s+//;
    my $pid=(split(/\s+/, $line))[0];
    print "Killing ssh with pid: $pid\n"    if $debug & 1;
    `kill $pid`;
  }
}

#################################
#    P l a y b a c k    M o d e
#################################

else
{
  # Control-C trap
  $SIG{"INT"}=\&sigInt;

  my $sel = new IO::Select(STDIN);

  # usleep expects usecs
  $delay*=1000000;

  error("networked playback file must start with '*'")    if $address ne '' && basename($playbackFile)!~/^\*/;
  error('playback file MUST contain a date')              if $playbackFile!~/(\d{8})/;
  $date=$1;
  $date=substr($date,4,2).'/'.substr($date,6,2)           if $options=~/d/;

  $fromTime.=':00'    if defined($fromTime) && length($fromTime)==5;
  $thruTime.=':00'    if defined($thruTime) && length($thruTime)==5;
  valTime('from', $fromTime);
  valTime('thru', $thruTime);

  # if thru time in collectl command, stop there; otherwise process the whole day
  my $thruSecs= (defined($thruTime)) ? getSecs($thruTime) : 86400;

  #    S t e p    1    -    O p e n    c o l l e c t l

  $somethingPrintedFlag=0;
  my ($interval1, $interval2, $interval3);

  my $firstSecs=86400;    # ultimately < 24:00:00
  my $headerState=0;      # don't have
  my $firstHost=1;
  my $activeHosts=$numHosts;
  for (my $i=0; $i<@hostnames; $i++)
  {
    my $host=$hostnames[$i];

    # We already have the hostname(s) for the local playback file(s) so rebuild
    # each name with only host-date so it matches only those we're interested in.
    my $tempCommand=$command;
    if ($localFlag)
    {
      my $playback=$playbackFile;
      my $dirname=dirname($playback);
      my $basename=basename($playback);
      my $filedate=($basename=~/(\d{8})/) ? $1 : '*';
      $playback="$dirname/$host*$filedate*";
      my $metaPlayback=quotemeta($playbackFile);
      $tempCommand=~s/$metaPlayback/$playback/;
    }

    # Either ssh to the local or remote systems
    # NOTE - tried skipping 'ssh' for local host but some kind of
    # interaction problem w/ stdin and it didn't work corectly
    my $uname=(!defined($usernames{$hostnames[0]})) ? '' : "$usernames{$hostnames[$i]}\@";
    my $access=($localFlag) ? "$Ssh -n localhost" : "$Ssh -n $uname$host";

    # First host?
    if ($i==0)
    {
      # When playing back local file(s), if they start with a wildcard, '$localhost' will
      # contain all the hostnames, one at a time.  NOTE for some shells/distros/whatever
      # I found I needed to surround the whole command in 's or error msgs got eaten
      my $cmd="$access '$Collectl $tempCommand --showheader' 2>&1";
      print "Command: $cmd\n"    if $debug & 1;
      my $header=`$cmd`;
      error($1)         if $header=~/(Error.*?)\n/;

      $header=~/Interval: (\S+)/;
      ($interval1, $interval2, $interval3)=split(/:/, $1);
      printf "Intervals: 1: %s  2: %s  3: %s\n",
          $interval1, defined($interval2) ? $interval2 : '', defined($interval3) ? $interval3 : ''
               if $debug & 1;
    }

    # in local mode, we don't use ssh OR surround the command with single quotes
    # also be sure to catch any remote errors written to STDERR
    my $cmd=($localFlag) ? "$Collectl $tempCommand --hr 0" : "$access '$Collectl $tempCommand --hr 0'";
    $cmd.="  2>&1";
    print "Command: $cmd\n"    if $debug & 1;
    $files{$host}->{pid}=open $files{$host}->{fd}, "$cmd |" or error("couldn't execute '$cmd'");
    $files{$host}->{hdr}=0;    # header not seen yet
  }

  #    S t e p    2    -    P r i m e     T h e    P u m p

  for (my $i=0; $i<@hostnames; $i++)
  {
    # Note that when we see the first host and have not yet seen a header, that I/O 
    # stream's header will be saved
    my $secs;
    my $host=$hostnames[$i];

    if (($secs=getNext($i))==-1)
    {
      $activeHosts--;
      delete $files{$host};
      next;
    }

    # let's take the opportunity of having just processed our first file to make sure -column
    # specifies a valid number, noting with newer versions of collectl we'll have already read
    # the header.
    error("invalid column number.  did you forget they start with 0?")
        if $i==0 && $column>=$numCols;

    # we want to start our analysis loop at the earliest entry returned by collectl.  This will
    # assure is times aren't synchornized we'll catch all records for all hosts using that as a
    # starting interval.
    $firstSecs=int($secs)    if $secs<$firstSecs;
  }

  #    S t e p    3    -    L o o p    T h r o u g h    T i m e    R a n g e

  $numReporting=0;

  my $interval=($subsys!~/[yYZ]/) ? $interval1 : $interval2;
  $interval=$interval3    if $subsys=~/E/;
  for (my $time=$firstSecs; !$ctrlCFlag && $time<=$thruSecs; $time+=$interval)
  {
    # if we exhausted the data for all hosts before hitting the thru time,
    # we need an alternate way out of this loop.
    last    if !$activeHosts;

    print "Time Loop: $time secs  Int: $interval  Limit: $thruSecs Reported: $numReporting\n"    if $debug & 2;
    @printStack=()    if $numReporting;   # start empty if something reported last interval
    @hostdata=()      if $numReporting;
    $numReporting=0;

    my %reported;
    my ($pushMin, $pushMax);
    for (my $i=0; $i<@hostnames; $i++)
    {
      my $host=$hostnames[$i];
      next    if !defined($files{$host});

      # We always have read up to the next sample, so if there is something for this host in
      # this interval (it could be in future), that falls in this timeframe add it to the
      # output stack.
      $reported{$host}=0;
      #print "HOST: $host FILE: $files{$host}->{secs} TIME: $time  INT: $interval\n";

      # see, we're doing multiple calls to getnext, one per line...
      while ($files{$host}->{secs}<($time+$interval))
      {
        # remove domain (it there)
	my $minihost=$host;
	$minihost=~s/\..*//    if $minihost!~/^\d/;

	my $pushSecs=$files{$host}->{secs};
	$pushMin=$pushSecs    if !defined($pushMin) || $pushSecs<$pushMin;
	$pushMax=$pushSecs    if !defined($pushMax) || $pushSecs>$pushMax;
	push @printStack, "$minihost $files{$host}->{line}";

        # only need for column data so why waste compute cycles
	$hostdata[$i]="$minihost $files{$host}->{line}"    if $cols ne '';

        # If the first line for this host count it as reporting and get next record
        # remember, if --thru, it will be passed to collectl who will return an EOF
        # when we hit it.
	$numReporting++    if !$reported{$host}++;
	my $seconds=getNext($i);
        if ($seconds==-1)
	{
	  $activeHosts--;
	  delete $files{$host};
	  last;
        }
      }
    }

    # delay if asked to, check for input and then print contents of stack
    # (there is an off chance nobody reported anything for this time period)
    Time::HiRes::usleep($delay);
    stdin()    if $sel->can_read(0);
    printInterval($pushMin, $pushMax)    if $numReporting;
  }

  # NOTE - previous bugs in collectl suppressing timestamps have tripped this error in the past.
  error("No data recorded for any hosts.  Is your date/timeframe correct?")    if !$somethingPrintedFlag && !$ctrlCFlag;
}

# reset terminal which includes re-enabling echo
print "\n";
Term::ReadKey::ReadMode(0)    if $readkeyFlag;

foreach my $host (keys %files)
{
    print "Killing pid $files{$host}->{pid} for '$host'\n"    if $debug & 1;
    `kill -9  $files{$host}->{pid}`;
    #close $files{$host}->{fd} or error("Failed to close playback file for '$host'");
}

# This runs as a thread!!!
sub check
{
  my $i=shift;

  # We can't use the Net::Ping module because some systems block pings and 
  # /bin/ping should be installed natively with suid privs so we CAN use that.
  my $out=`$Ping -c1 -w$pingTimeout $hostnames[$i] 2>&1`;
  $out=~/(\d+)% packet loss/;
  if ($1)
  {
    $threadFailure[$i]=1;
    return;
  }

  # Let's leave here in case it ever gets ressurected.
  # If ping fails, just return.  If it succeeds we'll try for an ssh
  # my $pingStatus=$ping->ping($hostnames[$i], $pingTimeout);
  # if (!$pingStatus)
  # {
  #   $threadFailure[$i]=1;
  #   return;
  # }

  # we need at least V1.67 of threads to do this because we need to be able to KILL
  # don't really care what this returns as long as it doesn't hang.  If it does
  # hang, the loop waiting on the threads will timeout.
  $threadFailure[$i]=-1;   # Assume ssh will fail
  if ($threadsVersion>=1.67)
  {
    my $switch=(!defined($sshswitch{$hostnames[$i]})) ? '' : $sshswitch{$hostnames[$i]};
    my $uname= (!defined($usernames{$hostnames[$i]})) ? '' : "$usernames{$hostnames[$i]}\@";
    my $command="$Ssh $switch $uname$hostnames[$i] $Collectl -v 2>&1\n";
    $command=~s/ -q//;    # remove 'quiet' switch so we see 'connection refused'
    print "Command: $command\n"    if $debug & 512;
    my $collectl=`$command`;

    # note if motd printed, 'collectl' may not start on the 1st line, so need /m on regx
    $threadFailure[$i]=0    if $collectl=~/^collectl V(\S+)/m;   # success!!!
    $threadFailure[$i]=64   if $threadFailure[$i]==0 && $1 lt '3.5';
    my $thisColVer=$1;

    my $hostname=$hostnames[$i];
    $hostname=(split(/\./, $hostname))[0]    if $hostname=~/[a-z]/i;    # drop domain name if there
    if ($threadFailure[$i]==0)
    {
      if (!defined($firstHostName))
      {
        $firstHostName=$hostname;
        $firstColVersion=$thisColVer;
      }
      print "***warning***  Collectl V$thisColVer on $hostname != V$firstColVersion on $firstHostName\n"
	  if $thisColVer ne $firstColVersion && !$quietFlag;
    }

    # couldn't get collectl version
    $threadFailure[$i]=2    if $collectl=~/command not found/;
    $threadFailure[$i]=2    if $collectl=~/not installed/;        # sometimes debian reports this instead of 'not found'
    $threadFailure[$i]=4    if $collectl=~/refused/;
    $threadFailure[$i]=8    if $collectl=~/Permission denied/s;
    $threadFailure[$i]=16   if $collectl=~/Could not resolve/s;
    $threadFailure[$i]=32   if $collectl=~/timed out during banner exchange/s;
  }
}

sub threadsDone
{
  my $num=shift;

  for (my $i=0; $i<$num; $i++)
  { return(0)    if $threads[$i]->is_running(); }
  return(1);
}

sub getNext
{
  my $hostnum=shift;
  my $line;
  my $host=$hostnames[$hostnum];

  my $fd=$files{$host}->{fd};
  while ($line=<$fd>)
  {
    # older versions of collectl that would do 'stty' in error() when not
    # connected to a terminal can generate 'stty' and that screws up output
    # also some cases of uninit vars in older versions so ignore them too
    chomp $line;
    error("$hostnames[$hostnum]: $1")    if $line=~/(Error.*)/;
    print ">>>$line\n"                   if ($line=~/^#/ && $debug & 64) || $debug & 128;
    next                                 if $oldColFlag && $line=~/^stty|^Use of uninit/;

    # this is a little messy.  If a MOTD, it precedes the header in this loop so ignore
    next                                 if !$files{$host}->{hdr} && $line!~/^#/;
    last                                 if $line!~/^#|^\s*$/;

    # Only happens with versions of collectl that don't support --showcolheaders
    push @headers, $line    if $hostnum==0 && !$gotHeadersFlag;

    # header seen so we can exit on next non-# line
    $files{$host}->{hdr}=1;
  }
  return(-1)    if !defined($line);

  # Just in case no data in selected file
  if ($line=~/(^No files processed)/)
  {
    print "$hostnames[$hostnum]: $1\n";
    return(-1);
  }

  # If the first header was just seen, reformat it and set $numCols as a side effect
  # note this can only happen with older collectls because we reformat much earlier
  # If a problem, $crtlCFlag will have been set by reformatHeaders()
  reformatHeaders()    if $hostnum==0 && !$gotHeadersFlag && scalar(@headers)>0;

  # Remove timestamp from line and save.  be sure to do it here since at
  # print time there's no knowledge of it.
  my $timestamp;
  if (!$plotFlag)
  {
    $line=~s/^(\S+) //;
    $timestamp=$1;

    # If date was specified, we've already pulled that out so now get the time
    if ($options=~/[dD]/)
    {
      $line=~s/^(\S+) //;
      $timestamp.=" $1";
    }
  }
  else # for plot format, get time but leave record alone
  {
    $line=~/^\S+\s+(\S+)/;
    $timestamp=$1;
    $timeFlag=0;
  }

  my $seconds=getSecs($timestamp);
  $files{$host}->{line}=sprintf("%s$line", ($timeFlag) ? "$timestamp " : "");
  $files{$host}->{secs}=$seconds;
  return($seconds);
}

sub stdin
{
  if ($debug & 32)
  {
    for (my $i=0; $i<length($input); $i++)
    { printf "BYTE: %d\n", unpack('C', substr($input, $i, 1)); }
  }

  # if using ReadKey, append latest chars to input string and checks for ^C;
  # otherwise just read a whole line terminated with RETURN.
  while (($readkeyFlag && defined(my $char=Term::ReadKey::ReadKey(-1))) ||
	 (!$readkeyFlag && ($input=<STDIN>)))
  {
    if ($readkeyFlag)
    {
      my $byte=unpack('C', $char);
      if ($byte==3)
      {
        $ctrlCFlag=1;
        print "\n";
        return;
      }
      $input.=$char;
    }
    last    if !$readkeyFlag;    # if not using ReadKey, this gets us out of loop
  }

  # Check for string terminated by RETURN
  if ($input=~/(.*)\n$/)
  {
    my $command=$1;
    $freezeFlag=0                      if $command!~/^f$/i;    # anything other than 'f' unfreezes display
    $freezeFlag=($freezeFlag+1) % 2    if $command=~/^f$/i;
    $revFlag=   ($revFlag+1)    % 2    if $command=~/^r$/i;
    $zeroFlag=  ($zeroFlag+1)   % 2    if $command=~/^z$/i;
    if ($command=~/^\d+$/)
    {
      print $bell         if $command>=$numCols;
      $column=$command    if $command<$numCols;
    }
    elsif ($command eq 'pu' || $command eq 'u') # page up
    {
      print $bell     if $startLine==1;
      $startLine-=$bodyLines;
      $startLine=1    if $startLine<1;
    }
    elsif ($command eq 'pd' || $command eq 'd') # page down
    {
      print $bell    if $startLine+$bodyLines-1>=$totalLines;
      $startLine+=$bodyLines;
      $startLine=$totalLines-$bodyLines+1    if ($startLine+$bodyLines-1)>$totalLines;
      $startLine=1    if $startLine<1;
    }
    $input='';
  }

  if ($input=~/${ESC}\[(.*)/)
  {
    $freezeFlag=0;    # anything unfreezes display

    my $key=$1;

    if ($key eq 'A')  #    up
    {
      $revFlag=1;
    }
    elsif ($key eq 'B')  # down
    {
      $revFlag=0;
    }
    elsif ($key eq 'C')  # right
    {
      print $bell    if $column == ($numCols-1);
      $column++      if $column != ($numCols-1);
    }
    elsif ($key eq 'D')  # left
    {
      print $bell    if $column == 0;
      $column--      if $column != 0;
    }
    elsif ($key eq '5~') # page up
    {
      print $bell     if $startLine==1;
      $startLine-=$bodyLines;
      $startLine=1    if $startLine<1;
    }
    elsif ($key eq '6~') # page down
    {
      print $bell    if $startLine+$bodyLines-1>=$totalLines;
      $startLine+=$bodyLines;
      $startLine=$totalLines-$bodyLines+1    if ($startLine+$bodyLines-1)>$totalLines;
      $startLine=1    if $startLine<1;
    }
    $input='';
  }
}

sub alarm
{
  my @value;
  my $index=0;


  # But first we need to copy the latest values to the print stack
  @printStack=();
  for (my $i=0; $i<$numHosts; $i++)
  {
    next    if !defined($host[$i]);    # no connected yet OR already disconnected

    # NOTE - when we call printInterval(), he'll remove the hostname and print it back
    # out padded accordingly.

    # Get double-buffering pointers
    my $currptr=$hostVars[$i]->{bufptr};
    my $prevptr=($currptr+1) % 2;
    my $maxcurr=$hostVars[$i]->{maxinst}->[$currptr];
    my $maxprev=$hostVars[$i]->{maxinst}->[$prevptr];
    print "HOST: $i  CUR: $currptr  PREV: $prevptr MAXCUR: $maxcurr MAXPREV: $maxprev\n"    if $debug & 256;

    for (my $j=0; $maxcurr!=-1 && $j<=$hostVars[$i]->{maxinst}->[$currptr]; $j++)
    {
      push @printStack, "$host[$i] $sample[$i]->[$j]->[$currptr]";
    }

    for (my $j=$hostVars[$i]->{maxinst}->[$currptr]+1; $maxprev!=-1 && $j<=$hostVars[$i]->{maxinst}->[$prevptr]; $j++)
    {
      push @printStack, "$host[$i] $sample[$i]->[$j]->[$prevptr]";
    }

    # column data needs to get stashed in a different data structure, indexed by 
    # host number in case we're doing single line output.  In that case we always have
    # the last sample in the current buffer.
    if ($cols ne '' && defined($sample[$i]->[0]->[$currptr]))
    {
      $hostdata[$i]="$host[$i] $sample[$i]->[0]->[$currptr]";
    }
  }

  # When we first start, we may not have even received the header, so wait for it...
  # also note that the timestamp for real-time counters determined by localtime()
#  print "PRINT: $gotHeadersFlag\n";  $gotHeadersFlag=1;
  printInterval()    if $gotHeadersFlag;
}

sub pdshFormat
{
  my $address=shift;

  # Break out individual address, putting 'pdsh' expressions back
  # together if they got split
  my $partial='';
  my $addressList='';
  foreach my $addr (split(/[ ,]/, $address))
  {
    # This is subtle.  The '.*' will match up to the rightmost '['.  If a ']'
    # follows, possibly followed by a string, we're done!  We use this same
    # technique later to determine when we're done.
    if ($addr=~/.*\[(.*)$/ && $1!~/\]/)
    {
      $partial.=",$addr";
      next;
    }

    if ($partial ne '')
    {
      $partial.=",$addr";
      next    if $partial=~/.*\[(.*)$/ && $1!~/\]/;
      $addr=$partial;
    }
    $addr=~s/^,//;
    $addressList.=($addr!~/\[/) ? "$addr " : expand($addr);
    $partial='';
  }
  $addressList=~s/ $//;
  return((split(/[ ,]/, $addressList)));
}

# Expand a 'pdsh-like' address expression
sub expand
{
  my $addr=shift;
  print "Expand: $addr\n"    if $debug & 1;

  $addr=~/(.*?)(\[.*\])(.*)/;
  my ($pre, $expr, $post)=($1, $2, $3);
  #print "PRE: $pre  EXPR: $expr  POST: $post\n";

  my @newStack;
  my @oldStack='';    # need to prime it
  foreach my $piece (split(/\[/, $expr))
  {
    next    if $piece eq '';    # first piece always blank

    # get rid of trailing ']' and pull off range
    $piece=~s/\]$//;
    my ($from, $thru)=split(/[-,]/, $piece);
    $from=~/^(0*)(.*)/;
    #print "PIECE: $piece FROM: $from THRU: $thru  1: $1  2: $2\n";

    my $pad=length($1);
    my $num=length($2);
    my $len=$pad+$num;
    my $spec=(!$pad) ? "%d" : "%0${len}d";

    $piece=~s/-/../g;
    $piece=~s/^0*(\d)/$1/;                # gets rid of leading 0s
    $piece=~s/([\[,.-])0*(\d)/$1$2/g;     # gets rid of other numbers with them

    my @numbers=eval("($piece)");

    undef @newStack;
    foreach my $old (@oldStack)
    {
      foreach my $number (@numbers)
      {
        my $newnum=sprintf("$spec", $number);
	push @newStack, "$old$newnum";
      }
    }
    @oldStack=@newStack;
  }

  my $results='';
  foreach my $spec (@newStack)
  { $results.="$pre$spec$post "; }

  return $results;
}

# Stolen from colgui, but since modified...
sub getReturnAddress
{
  my $address=shift;
  my $myaddr;

  # If only one network UP, that's the address to use.  Note newer versions of
  # ifconfig, at least on RHEL 7.0 use 'broadcast' instead of 'Bcast'
  my $cmd="$Ifconfig 2>/dev/null | $Grep -E 'Bcast|broadcast'";
  print "Command: $cmd\n"    if $debug & 1;
  my @lines=`$cmd`;
  if (@lines==1)
  {
    $myaddr=(split(/\s+/, $lines[0]))[2];
    $myaddr=~s/.*://;    # this is a no-op with newer ifconfig
    print "Got address from ifconfig: $myaddr\n"    if $debug & 1;
    return ($myaddr);
  }

  my ($destaddr, $gateway, $mask, $interface, $octet);
  my (@addrOctets, @destOctets, @maskOctets);

  print "Get return address associated with $address from 'route'\n"    if $debug & 1;
  @addrOctets=split(/\./, $address);
  open ROUTES, "$Route|" or error("Couldn't execute '$Route'");
  foreach my $line (<ROUTES>)
  {
    next    if $line!~/^\d|^default/;
    chomp $line;

    ($destaddr, $gateway, $mask, $interface)=(split(/\s+/, $line))[0,1,2,7];

    # Note if default route we don't have any digits in here, but since the
    # mask is 0.0.0.0 if will kick on on the first test.
    @destOctets=split(/\./, $destaddr);
    @maskOctets=split(/\./, $mask);
    for (my $i=0; $i<4; $i++)
    {
      # we're guaranteed a hit since the default starts with 0.
      if ($maskOctets[$i]==0)
      {
        close ROUTES;
        $myaddr=`$Ifconfig $interface | grep 'inet '`;
        $myaddr=(split(/\s+/, $myaddr))[2];
        $myaddr=(split(/:/, $myaddr))[1];    # another no-op for newer ifconfig
	print "Got address from route for $interface: $myaddr\n"    if $debug & 1;
        return ($myaddr);
      }
      last    if ($addrOctets[$i] & $maskOctets[$i])!=$destOctets[$i];
    }
  }

  # The only way to make sure this never happens is to put the code
  # in to catch it.
  print "Can't find default Route\n";
  #error("Can't find default route in $Route");
}

sub reformatHeaders
{
  printf "Reformatting headers%s\n", $oldColFlag ? ': *** using OLD collectl ***' : ''    if $debug & 1;

  # First, get rid of stuff we don't want like blank lines and 'RECORD'
  my @save=@headers;
  @headers=();
  foreach my $line (@save)
  {
    next    if $line=~/^\s*$|RECORD/;
    push @headers, $line;
  }

  my $diff=($hostlen>8) ? $hostlen-8 : 0;
  my $hostpad=' 'x$diff;
  $hostpad.=  ' 'x9    if $timeFlag;
  my $padChars=length($hostpad);

  # most of the time we're dealing with multi-line header and NOT plot format
  # also note that it's the responsibility of earlier error checking to make
  # sure switch combos are legit

  # While it might be possible to combine a lot of this into less cases, it's
  # easier to test when different types of output are grouped this way. Start
  # by replacing the Time field with Host before we start shifting things.
  $headers[-1]=~s/#Time/#    /;

  if (!$plotFlag)
  {
    if ($expFlag)
    {
      $headers[1]=~s/^#/#$hostpad/;
      $headers[2]=~s/^#/#$hostpad/    if defined($headers[2]);
    }
    elsif (($subsys=~/[a-z]/ || $numImports) && !$verbFlag)
    {
      # not sure why I used to skip shifting line 1, but I clearly
      # need to do it with some --imports
      for (my $i=0; $i<@headers; $i++)
      { $headers[$i]=~s/^#/#$hostpad/; }
    }
    elsif (($subsys=~/[a-z]/ || $numImports) && $verbFlag)
    {
      # with verbose or imports we DON'T shift line 0, though
      # seeing comment above I'm not sure why this is here
      $headers[1]=~s/^#/#$hostpad/;
      $headers[2]=~s/^#/#$hostpad/    if defined($headers[2]);
    }
    else
    {
      $headers[1]=~s/^#/#$hostpad/             if $subsys=~/[A-Y]/;
      $headers[2]=~s/ Name/${hostpad}Name /    if $subsys=~/[DY]/;
      $headers[1]=~s/ PID/${hostpad} PID/      if $subsys=~/[Z]/;
    } 

    # we now have a header line that starts with "#    " and
    # normally we just replace it with '#Host', but in playback
    # mode we might have to deal with date/time as well.
    if ($playbackFlag)
    {
      my $dt='';
      $dt.='Date  '       if $options=~/d/;
      $dt.='Date     '    if $options=~/D/;
      $dt.='Time     '    if $timeFlag;

      my $dtlen=length($dt);
      $headers[-1]=~s/(.{$hostlen}) .{$dtlen}/${1} $dt/;
    }

    # now that we're padded in the right number of spaces for the hostname
    # replace the first 5 with the appropriate text
    $headers[-1]=~s/.{5}/#Host/;

    # this is a little tricky because in single line mode while our earlier
    # trick works with -oD and -od, it doesn't work with -oT in non-plot mode
    if (!$plotFlag && $options=~/T/)
    {
      for (my $i=0; $i<@headers; $i++)
      {
        if ($i==scalar(@headers)-1)
	{ $headers[$i]=~s/#Host/#Host Time    /; }
	else
	{ $headers[$i]=~s/#/#         /; }
      }
    }
  }
  else
  {
    # since -P is identical everywhere, let's just let the code above replace Date/Time with
    # 'host' and then we'll put it back.  Also, the header is only 1 line.
    $headers[0]=~s/^.*?\[/#Host Date Time /    if $plotFlag;  
  }

  # Build an array of column positons for first char of each header column for use with bolding
  my $num=1;
  my $lastChar='x';   # doestn't really matter
  $headerPos[0]=1;    # first entry always column 1
  for (my $i=1; $i<length($headers[-1]); $i++)
  {
    my $char=substr($headers[-1], $i, 1);
    $headerPos[$num++]=$i    if $char!~/\s/ && $lastChar=~/\s/;
    $lastChar=$char;
  }

  my @temp=split(/\s+/, $headers[-1]);
  if ($colhelpFlag)
  {
    $colhelp='#  00';
    for (my $i=1; $i<@headerPos; $i++)
    {
      my $padChars=$headerPos[$i]-length($colhelp)+(length($temp[$i])-2);
      my $pad=' 'x$padChars;
      $colhelp.=sprintf("$pad%02d", $i);
    }
  }

  # Now figure out how many columns there are for verifying -column and -cols
  $numCols=@temp;
  if ($column>=$numCols || ($cols ne '' && $maxColNum>=$numCols))
  {
    printf "%s specifies a column > max, which is %d\n",
        ($cols eq '') ? '-column': '-cols', $numCols-1;
    $ctrlCFlag=1;
  }
  return(!$ctrlCFlag);  # noting the non-error state is 0
}

sub printInterval
{
  my $minSecs=  shift;
  my $maxSecs=  shift;

  my @value;
  my $unique=0;
  my $numFlag=1;

  return    if $ctrlCFlag;   # can't trust sample...

  #############################################
  #    S i n g l e    L i n e    F o r m a t
  #############################################

  # Here we only select specific columns for printing...
  if ($cols ne '')
  {
    my $numCols=scalar(@columns);
    my $wider=$colwidth+2;  # extra width for totals columns
    $somethingPrintedFlag=1;

    #    H e a d e r

    if ($numLines==-1 || $maxLines!=0 && (++$numLines % $maxLines)==0)
    {
      # there's a blank line after the header, but a cr at end of last
      # line that would scolls header off, so the height is really 1 less
      $numLines+=2;

      printf "\n";
      my $datetime='';
      $datetime.='#Date    Time    '    if $options=~/D/;
      $datetime.='#Date Time    '       if $options=~/d/;
      $datetime.='#Time   '             if $options=~/T/;
      $datetime.='    '                 if $options=~/m/;
      my $dtpad=' ' x length($datetime);

      # write name of column over each set of hostnames
      print $dtpad;
      for (my $i=0; $i<@columns; $i++)
      {
        for (my $j=0; $j<@hostnames; $j++)
	{
	  # note that because of the way the header names are stored (which DO include
          # a timestamp), we need to skip printing date/timestamps when -o not specified
          my $col=($options=~/[TdD]/ || $plotFlag) ? $columns[$i]-1 : $columns[$i];

	  if ($j==0)
	  {
	    printf " %-${colwidth}s", @headernames ? $headernames[$col] : '???';
	  }
	  else
	  {
	    printf " %${colwidth}s", '';
	  }
	}
	print '   ';    # account for ' | '
      }
      print "\n";

      if (!$colnodetFlag)
      {
	print $datetime;
        for (my $i=0; $i<$numCols; $i++)
        {
          for (my $j=0; $j<@hostnames; $j++)
          {
	    # if hostname contains ANY alpha chars, it's not an IP address so only use hostname piece
            my $hostname=($hostnames[$j]=~/[a-zA-Z]/) ? (split(/\./, $hostnames[$j]))[0] : $hostnames[$j];
	    my $len=length($hostname);
            my $start=($len-$colwidth>0) ? $len-$colwidth : 0;
  	    my $hostTrunc=substr($hostname, $start, $colwidth);
            printf " %${colwidth}s", $hostTrunc;
          }
          print ' | '    if $numCols>1 && $i!=$numCols-1;
        }
      }

      if ($colTotalFlag)
      {
        print ' | '    if !$colnodetFlag;
        for (my $i=0; $i<@columns; $i++)
        {
	  my $col=($plotFlag || $options=~/[TdD]/) ? $columns[$i]-1 : $columns[$i];
          printf " %${wider}s",  @headernames ? $headernames[$col] : '???';
        }
      }
      print "\n";
    }

    #    B o d y

    # We need the current time outside the timestamp printing section below, 
    # mainly so we can be sure out timestamp tests later on use today's date.
    my ($seconds, $usecs)=Time::HiRes::gettimeofday();
    my ($sec, $min, $hour, $day, $mon, $year)=localtime($seconds);

    # Preface with date/timestamp?  But even if so, we use OUR date/time...
    if ($timeFlag)
    {
      if (!$playbackFlag)
      {
        my ($seconds, $usecs)=Time::HiRes::gettimeofday();
        my ($sec, $min, $hour, $day, $mon, $year)=localtime($seconds);
        my $date=($options=~/d/) ? sprintf("%02d/%02d", $mon+1, $day) : sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
        my $time=sprintf("%02d:%02d:%02d", $hour, $min, $sec);
        $time.=substr(sprintf(".%06d", $usecs),0,4)    if $options=~/m/;
        printf "%s", ($options=~/[dD]/) ? "$date $time" : $time;
      }
      else
      {
        # always print time, date optional
        printf "%s%s", ($options=~/[dD]/)? "$date " : '', putSecs($minSecs);
      }
    }

    my @total;
    my $timeNow=time;
    for (my $i=0; $i<$numCols; $i++)
    {
      # we may end up adjusting column down in plot format
      my $col=(!$plotFlag) ? $columns[$i] : $columns[$i]-1;

      $total[$col]=0;
      for (my $j=0; $j<@hostnames; $j++)
      {
        # When running in real-time mode and data exists, make sure it isn't stale
        if (!$playbackFlag && defined($hostdata[$j]))
	{
          my $bufptr=$hostVars[$j]->{bufptr};
          my $time=$hostVars[$j]->{lasttime}->[$bufptr];
	  my $hh=substr($time, 0, 2);
	  my $mm=substr($time, 3, 2);
	  my $ss=substr($time, 6);

          # NOTE - we're using current day/month/year
	  my $timeSample=timelocal($ss, $mm, $hh, $day, $mon, $year);
	  delete $hostdata[$j]    if $maxDataAge<($timeNow-$timeSample);
	  my $diff=$timeNow- $timeSample;
	  #printf "realtime -- MaxAge: $maxDataAge  Now: $timeNow Sample: $timeSample  AGE: %d\n", $timeNow-$timeSample;
        }

        my $data;
        if (defined($hostdata[$j]))
        {
          $data=(split(/\s+/, $hostdata[$j]))[$col];
	  $data/=1000                        if $col1Flag &&   !defined($colsNoDiv[$col]);
	  $data/=1024                        if $colKFlag &&   !defined($colsNoDiv[$col]);
	  $data=int(10*log($data)/log(10))   if $colLogFlag && !defined($colsNoDiv[$col]) && $data>=1;

          $data=int($data);
 	  $total[$col]+=$data;

          # pretty rare...
          if ($data<0 && defined($negdataval))
          {
	    $total[$col]-=$data;    # do not include in total
            $data=$negdataval;
          }
        }
        else
        {
	  $data=$nodataval;
        }
	printf " %${colwidth}s", $data    if !$colnodetFlag;
      }
      print ' | '    if !$colnodetFlag && $numCols>1 && $i!=$numCols-1;
    }

    if ($colTotalFlag)
    {
      print ' | '     if !$colnodetFlag;
      foreach my $column (@columns)
      {
	  # This is clearly something weird!  If I decrement $col instead of
	  # doing what I'm doing it clobbers @columns
	  my $col=(!$plotFlag) ? $column : $column-1;
	
	my $tot=$total[$col];
	printf " %${wider}d", defined($tot) ? $tot : -1;
      }
    }

    print "\n";
    @hostdata=();
    return;
  }

  #    B u i l d    C o m m o n    T i m e s t a m p

  # Build timestamp, noting it's different in playback vs real-time mode
  my $timestamp;
  if ($playbackFlag)
  {
    # if more than one time, report as a range
    $timestamp=putSecs($minSecs);
    $timestamp.=sprintf("-%s", putSecs($maxSecs))    if $maxSecs!=$minSecs;
    $timestamp.="  Reporting: $numReporting of $numHosts";
  }
  else
  {
    $timestamp=localtime(time);
    $timestamp.="  Connected: $numReporting of $numHosts";
  }

  #############################
  #    N o     S o r t i n g
  #############################

  if ($nosortFlag)
  {
    # Same as when sorting except no-bolding
    printLine("# $timestamp")    if ($subsys=~/[a-z]/ || $numImports) && !$verbFlag;
    chomp   $headers[0];
    my $line=sprintf("$headers[0] %s", ($subsys=~/[A-Z]/ || $verbFlag) ? $timestamp : '');
    printLine($line);
    printLine($headers[1]);
    printLine($headers[2])    if defined($headers[2]);

    foreach my $line (@printStack)
    {
      # also as below we need to remove hostname and put it back properly sized
      $line=~s/(^\S+)//;
      my $host=$1;
      printf "%-${hostlen}s$line\n", $host;
      $somethingPrintedFlag=1;
    }
    return;
  }

  #############################
  #    S o r t    F o r m a t
  #############################

  # when not freezing display, we clear out and repopulate sort hash each cycle
  undef %sort    if !$freezeFlag;

  # only go through look when NOT freezing display
  $totalLines=0;
  for (my $i=0; !$freezeFlag && $i<@printStack; $i++)
  {
    # note in ealier versions of collectl an extra hostname was part of RECORD line
    my $line=$printStack[$i];
    next    if $line=~/^#|RECORD/;

    $totalLines++;
    $value[$i]=(split(/\s+/, $line))[$column];
    $value[$i]=''    if !defined($value[$i]);    # can happen with optional fields, as in the case of plugins

    #    N o n - I n t e g e r    F i e l d s   ( s a v e    a    f e w    n a n o - s e c s )

    # Since pure time stamps are fixed width, they'll sort fine as strings
    if ($subsys=~/E/)
    {
      $value[$i]=$1*100+$2    if $value[$i]=~/(\d+)\.(\S+)/;
    }
    elsif ($subsys=~/Y/ && $column==11)
    {
      # always a percentage
      $value[$i]=~/(\d+)\.(\d+)/;
      $value[$i]=$1*100+$2;
    }
    elsif ($subsys=~/Z/)
    {
      $value[$i]=$1*3600+$2*60+$3     if $value[$i]=~/(\d+):(\S+):(.*)/;   # Timestamp
      $value[$i]=$1*60+$2             if $value[$i]=~/(\d+):(\S+)/;        # AccuTime  -> seconds
      $value[$i]=$1*100+$2            if $value[$i]=~/(\d+)\.(\S+)/;       # SysT/UsrT -> jiffies
    }

    # handle time, noting we can have a LOT more than 24 hours
    if ($value[$i]=~/:/)
    {
      my ($hour, $mins, $secs)=split(/:/, $value[$i]);
      if ($mins=~/\./)    # if < 1 hour, format is mm:ss.ff
      {
        $secs=$mins;
	$mins=$hour;
	$hour=0;
      }
      $value[$i]=$hour*3600+$mins*60+$secs;
    }

    # handle K, M, G
    if ($value[$i]=~s/^(\d+)([KMG])$/$1/)
    {
      my $mult=$2;
      $value[$i]*=$K    if $mult eq 'K';
      $value[$i]*=$M    if $mult eq 'M';
      $value[$i]*=$G    if $mult eq 'G';
    }
    #print "VAL: $value[$i]\n";
    $numFlag=0    if $value[$i]!~/^[0-9.-]*$/;     # contains non-numeric char
    next          if $zeroFlag && $numFlag && $value[$i]==0;

    # Use hash to sort results, noting we could still have a string also assume
    # this is not perfect, but we need a unique descriminator to make sure duplicates
    # are dealt with so use as a fraction to retain numeric values.
    my $sortkey=sprintf("%s%s%d", $value[$i], ($value[$i]=~/\./) ? '' : '.', $unique++);    # make all look like numbers
    $sort{$sortkey}=$i;
    #printf ">>$value[$i]<< KEY: $sortkey  LINE: $printStack[$i]\n";
  }

  my @keys;
  if ($numFlag)
  { @keys=($revFlag) ? (sort{$a <=> $b} keys %sort) : reverse sort{$a <=> $b} keys %sort; }
  else
  { @keys=($revFlag) ? (sort{$a cmp $b} keys %sort) : reverse sort{$a cmp $b} keys %sort; }

  #    P r i n t    H e a d e r s

  print "$Home"    if $homeFlag;

  # we need a local copy so we can bold it w/o destroying original
  my @temp=@headers;
  $temp[-1]=~s/(.{$headerPos[$column]})(\S+)/$1$bold$2$noBold/    if $boldFlag;

  # no room in summary headers for timestamp so print above
  my $state=($freezeFlag) ? ' >>>column sorting disabled<<<' : '';

  my $endLine=$startLine+$bodyLines-1;
  $endLine=$totalLines    if $endLine>$totalLines;
  my $display=($startLine>1 || $endLine<$totalLines) ? "  Displaying: lines $startLine thru $endLine out of $totalLines" : '';
  printLine("# $timestamp$state$display")    if ($subsys=~/[a-x]/ || $numImports) && !$verbFlag;
  chomp   $temp[0];
  my $line=sprintf("$temp[0] %s", ($subsys=~/[yA-Z]/ || $verbFlag) ? "$timestamp$display" : '');

  printLine($line);

  # if colhelp need to insert in different locations
  if (!defined($temp[2]))
  {
    printLine($colhelp)    if $colhelpFlag;
    printLine($temp[1]);
  }
  else
  {
    printLine($temp[1]);
    printLine($colhelp)    if $colhelpFlag;
    printLine($temp[2]);
  }

  #    P r i n t    B o d y

  # always leave room for header and possible column help
  my $skip=$startLine;
  my $lineCount=scalar(@headers);
  $lineCount++    if ($subsys=~/[a-z]/ || $numImports) && !$verbFlag;    # this format has 1 extra line
  $lineCount++    if $colhelpFlag;

  foreach my $key (@keys)
  {
    next    if --$skip>0;    # skip any lines if $startLine>1
    my $i=$sort{$key};

    # Remove the hostname from the line
    $printStack[$i]=~s/(^\S+)//;
    my $host=$1;

    # we never terminate last line in screen mode with a CR
    my $lastLine=(++$lineCount==$maxLines) ? 1 : 0;
    #print "$lineCount ";

    # and now print the line with the hostname padded accordingly but no \n yet
    # can't use printLine() because we don't always do the CR at the end 
    $somethingPrintedFlag=1;
    $line=sprintf("%-${hostlen}s$printStack[$i]", $host);
    printLine($line, $lastLine);
    last    if $lastLine;
    next;
  }
  print "\n"    if !$homeFlag || $noEscapeFlag || $finalCr;

  # clear remainder of display and even if NOT in real-time mode there's nothing
  # below our current position.
  print "$Clr"    if $homeFlag;
}

# in home mode, clean end of each line
sub printLine
{
  my $line=shift;
  my $last=shift;

  print $line;
  print $Cleol    if $homeFlag;
  print "\n"      if !$last;
}

sub getHeaders
{
  my $access= shift;
  my $command=shift;

  # in case -c or -i included, they conflict with -showheader
  $command=~s/-c\s*\S+//;
  $command=~s/-i\s*:*\d+//;

  my $cmd="$access $Collectl $command --showcolheaders";
  $cmd=~s/--fr\S+\s+\S*//;
  print "Command: '$cmd'\n"    if $debug & 1;
  my $headers=`$cmd 2>&1`;

  # if an older version of collectl, we'll get an error that --showcolheaders
  # is an invalid switch so set a flag as a reminder.  In the correct version,
  # even in local mode with wildcarded filenames, that's ok too because collectl
  # exits after processing very first one.
  $oldColFlag=($headers=~/showcolheaders/) ? 1 : 0;
  @headers=split(/\n/, $headers)    if !$oldColFlag;

  # We can still get the headers but now we're going to back 1 or more
  # lines of data which we need to ignore and leave out of @headers
  if ($oldColFlag)
  {
    # if -p, we need to remove -p and the filespec so that we can add in -i & -c
    # which are incompatible
    if ($playbackFlag)
    {
	# Since we know the format of the filespec is '-p "filespec"' OR --pla* "filespec"'
        # look for something that matches either (one or more '-', whitespace and "filename")
        # and remove it all from the command
	my $meta=quotemeta($playbackFile);
	$command=~s/-+\S+\s+"$meta"//;
	$command=~s/-p\s*\S+|-pla\S+\s+\S+//;
	$command=~s/--fr\S+\s+\S+|--th\S+\s+\S+//g;
    }

    # since -i0 is special for secondary intervals, lets just make it small
    # enough to not be noticable
    my $tempInterval=.01;
    $tempInterval='.01:.01'     if $subsys=~/[yYZ]/;
    $tempInterval='.01::.01'    if $subsys=~/E/;

    # This will get data as well as the header so need to remove the data below
    $cmd="$access $Collectl $command -i$tempInterval -c1 --quiet";
    print "Command: '$cmd'\n"    if $debug & 1;
    $headers=`$cmd 2>&1`;

    foreach my $line (split(/\n/, $headers))
    {
      next    if $line=~/^\s*$/;
      last    if $line!~/^#/;
      push @headers, $line;
    }
  }

  # in some rare cases, collectl can throw errors that ultimately result in showing up in
  # the header, so let's make a quick pass and remove any lines that don't begin with a '#'
  for (my $i=@headers-1; $i>=0; $i--)
  {
    splice(@headers, $i, 1)    if $headers[$i]!~/^#/;
  }

  # we only have an error to report if not the missing -showcolheaders switch
  # since that simply means we need to get the header from the return data
  # BUT if an ssh problem we need to catch that too
  error("collectl: $headers")   if $headers=~/^Error/m && $headers!~/showcolheaders/;
  error("ssh: $headers")        if $headers=~/Connection refused/;
  return(@headers);
}

sub showHeaders
{
  my $header=$headers[-1];
  my @fields=split(/\s+/, $header);

  # assumes single line format but also useful for real-time AND playback mode
  $columns[0]=$column    if $cols eq '';
  my $selected=(@columns) ? '' : '(None Selected) ';
  print "\n>>> Headers $selected<<<\n";

  my $maxWidth=0;
  foreach my $field (@fields)
  { $maxWidth=length($field)    if length($field)>$maxWidth; }

  # Need to process columns in reverse since bolding shifts them to the right
  for (my $i=@columns-1; $i>=0; $i--)
  {
    my $col=$columns[$i];
    if ($col>=@fields)
    {
      print "Invalid column number: $col\n";
      next;
    }

    my $colname=$fields[$col];
    my $colmeta=quotemeta($colname);

    $header=~s/(.{$headerPos[$col]})(\S+)/$1$bold$2$noBold/;
  }
  $headers[-1]=$header;
  foreach my $header (@headers)
  { print "$header\n"; }
  print "\n";

  my $curcol=0;
  print ">>> Column Numbering <<<\n";
  for (my $i=0; $i<@fields; $i++)
  {
    if (($curcol+$maxWidth+4)>$termWidth)
    {
      print "\n";
      $curcol=0;
    }
    printf "%2d %-${maxWidth}s ", $i, $fields[$i];
    $curcol+=$maxWidth+4;
  }
  print "\n";
}

sub valTime
{
  my $name=shift;
  my $time=shift;

  if (defined($time))
  {
    error("invalid '$name' time")     if $time!~/(\d{2}):(\d{2}):(\d{2})/;
    error("invalid '$name' hours")    if $1>24;
    error("invalid '$name' mins")     if $2>60;
    error("invalid '$name' secs")     if $3>60;
  }
}

sub getSecs
{
  my $time= shift;

  # The timestamp could be just the time but includes msec, so if longer that hh:mm:ss.xxx
  # it must have a date as well so remove it, remembering we only run against a single date.
  $time=(split(/ /, $time))[1]    if length($time)>12;

  # Note if time contains msec, we preserve it
  my $secs=substr($time, 0, 2)*3600+substr($time, 3, 2)*60+substr($time, 6);
  return($secs);
}

sub checkTime
{
  my $time=shift;
  my ($hour,$mins,$secs)=split(/:/, $time);

  $secs=0      if !defined($secs);    # to make tests below work;
  return(0)    if $hour>24 || $mins>59 || $secs > 59;
  return(0)    if $hour!~/^\d+$/ || $mins!~/^\d+$/ || $secs!~/^\d+$/;
  return(1);
}


sub putSecs
{
  my $seconds=shift;

  my $hours=int($seconds/3600);
  my $mins= int(($seconds-3600*$hours)/60);
  my $secs= $seconds-3600*$hours-60*$mins;
  my $msec= (split(/\./, $secs))[1];
  my $timestamp=sprintf("%02d:%02d:%02d", $hours, $mins, $secs);
  $timestamp.=sprintf(".%03d", $msec)    if defined($msec);
  return($timestamp);
}

sub sigInt
{
  $ctrlCFlag=1;
  print "^C detected...\n"    if $debug & 1;
}

sub error
{
  # Be sure to reset terminal characteristics
  print "$Program: $_[0]\n";
  Term::ReadKey::ReadMode(0)    if $readkeyFlag;
  exit;
}

sub help
{
print <<EOF;
usage: colmux -address -command [-switches]

Common Switches
  -address    addr[,addr]  comma separated list of address to connect or filename
  -command    string       collectl command string
  -help                    print this message
  -hostwidth  number       minimum width to use for printing hostname [def=$hostWidth]
  -lines      number       limit displays to this number of lines
  -noescape                disable printing ALL escape sequences
  -port       port         port remote collectl should use for communications
  -sshkey     file         file containing ssh public key to pass with ssh -i
  -sudo                    preface collectl commands with 'sudo'
  -test                    show column headers & numbering
  -username   name         sets initial username for ALL hosts
  -version                 show version and exit

Playback Mode Specific
  -delay      seconds      time to pause between playback output (fractions welcome)
  -home                    move cursor home between playback samples (top-like)
  -hostfilter addr[,addr]  pdsh-like address list only apply to local filenames 
  -nosort                  do not sort output and ignore bolding and -lines

Multi-Line Format
  -colhelp                 include numbers over each column for easier identification
  -column     num          select column number for sorting, see -test
  -finalcr                 DO print a final cr, see man page for why you could want this
  -hostformat char:piece   allows you display a piece of a hostname based on char
  -nobold                  during file playback, disable highlighting of column names
  -reverse                 sort in decending order
  -zero                    do not include columns of zero

Single-Line Format
  -col1000                 divide each column by 1000
  -colk                    divide each column by 1K (1024)
  -collog10                convert each column to log10, except when -colnodiv
                           see man page for details
  -cols       nums         select which columns to display on 1 line, see -test
  -colnodet                only print totals
  -colnodiv   cols         do NOT apply colk or col1000 to comma-separated col numbers
  -colnoinst               do NOT include instance names in totals
  -coltotal                print totals for each column to the right
  -colwidth                width of each column [default=$colwidth]

Exception Reporting Specific
  -age        number       report latest value within number of intervals [def=$age]
  -negdataval val          report negative numbers as 'val'
  -nodataval  val          report this instead of -1 when no data seen within -age

Diagnostics
  -debug      number       primarily for development/debugging, see source code
  -nocheck                 do not check hosts (ping/ssh/collectl) before connecting
  -quiet                   do not report warnings for mismatched collectl versions
  -reachable               if specified, ALL hosts must be pingable/ssh-able

Miscellanous
  -colbin     path         use this path instead of /usr/bin/collectl for remote collectl
  -keepalive  secs         pass this in the ssh command as '-o ServerAliveInterval=secs'
                             to prevent ssh exiting early from an inactive ssh connection
  -retaddr    addr         tell collectl to connect back to this address.
                             start with -deb 1 to see address collectl told to use
  -timeout    secs         use this timeout for remote collectl to connect back
                             requires collectl V3.6.4 or better

$Copyright;
EOF
exit;
}
