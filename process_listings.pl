#!/usr/bin/perl -w

use strict;
use warnings;

use Mojo::DOM;
use Config::Tiny;
use Getopt::Long;

my $infile;
my $offline_myth_channels;

usage() if ( @ARGV < 1 || !GetOptions('v=s' => \$infile, 'm=s' => \$offline_myth_channels));

sub usage
{
	print "\nUsage: process_listings.pl -v <path_to_VM_HTML> [-m <path_to_offline_Myth_HTML>]\n\n";
	exit;
}

my $config_file = "config.ini";

my $config = Config::Tiny->read($config_file);

my $bash                     = $config->{Paths}{bash};
my $wget                     = $config->{Paths}{wget};
my $grabber                  = $config->{Paths}{grabber};
my $xmltv_config             = $config->{Paths}{xmltv_config};
my $unmatched_VM_chanlist    = $config->{Paths}{unmatched_VM_chanlist};
my $unmatched_XMLTV_chanlist = $config->{Paths}{unmatched_XMLTV_chanlist};
my $username                 = $config->{MythWebAuth}{username};
my $password                 = $config->{MythWebAuth}{password};

my @VMchannels = parse_VM_channels($infile);

my %xmltv_hash = retrieve_XMLTV_channels();

my $name_mapping_hash_r = $config->{ChannelNameMapping};

my $unmatched             = 0;
my @unmatched_vm_channels = ();

foreach my $channel (0 .. scalar(@VMchannels)-1)
{
	my $VMchannel      = $VMchannels[$channel]->{'UnivName'};
	my $VMchannel_name = $VMchannels[$channel]->{'Name'};
	
	my $mapped_univ_name;
	
	if (defined $VMchannel_name && defined $name_mapping_hash_r->{$VMchannel_name})
	{
		($mapped_univ_name = uc($name_mapping_hash_r->{$VMchannel_name})) =~ s/\s+//og;
	}

	if (defined $VMchannel)
	{
		if (defined $xmltv_hash{$VMchannel})
		{
			$VMchannels[$channel]->{'ID'}       = $xmltv_hash{$VMchannel}->[0];
			$VMchannels[$channel]->{'LongName'} = $xmltv_hash{$VMchannel}->[1];
			
			delete $xmltv_hash{$VMchannel};
		}
		elsif (defined $name_mapping_hash_r->{$VMchannel_name} &&
                       defined $xmltv_hash{$mapped_univ_name})
		{
			$VMchannels[$channel]->{'ID'}       = $xmltv_hash{$mapped_univ_name}->[0];
			$VMchannels[$channel]->{'LongName'} = $xmltv_hash{$mapped_univ_name}->[1];
			
			delete $xmltv_hash{$mapped_univ_name};
		}
		else
		{
			push @unmatched_vm_channels, $VMchannel_name;
			$unmatched++;
		}
	}
}

# Case insensitive sort of unmatched VM channels

my @sorted_unmatched_vm_channels = sort {lc $a cmp lc $b} (@unmatched_vm_channels);

Write_File($unmatched_VM_chanlist, \@sorted_unmatched_vm_channels);

my $num     = 0;
my %id_hash = ();

foreach my $channel (grep {defined $VMchannels[$_]->{'ID'}} (0 .. scalar(@VMchannels)-1))
{
	$num ++;
		
	$id_hash{$VMchannels[$channel]->{'ID'}} = [-1, $channel];
}

my @sorted_unmatched_XMLTV_channels = sort {lc $a cmp lc $b} map {$xmltv_hash{$_}->[1]} sort (keys %xmltv_hash);

Write_File($unmatched_XMLTV_chanlist, \@sorted_unmatched_XMLTV_channels);

print "INFORMATION: $num channels from VM EPG have XMLTV listings data, $unmatched unmatched\n";

parse_myth_channels($offline_myth_channels, \%id_hash);

my $to_be_removed   = "";
my $to_be_added     = "";
my $add_new         = "";
my $change_existing = "";

foreach my $id (keys %id_hash)
{
	$to_be_added   .= ($id_hash{$id}[0] == -1 ? "$id\n" : "");
	$to_be_removed .= ($id_hash{$id}[0] ==  1 ? "$id\n" : "");
	
	if (defined $id_hash{$id}[1] && defined $id_hash{$id}[2] && $id_hash{$id}[1] != $id_hash{$id}[2])
	{
		$change_existing .= "Channel ID $id should be moved from channel no. ".$id_hash{$id}[2]." to ".$id_hash{$id}[1]."\n";
	}
	elsif (defined $id_hash{$id}[1] && !defined $id_hash{$id}[2])
	{
		$add_new .= "Channel ID '$id' should be given channel no. ".$id_hash{$id}[1]."\n";
	}
}

print "\nTo be added:\n$to_be_added\n";
print "To be removed:\n$to_be_removed\n";
print "New channels:\n$add_new\n";
print "Channel changes:\n$change_existing\n";

sub Read_File
{
  my ($filename) = @_;
	
  open(my $fh, "<", $filename) or die "Can't read $filename: $!\n";
  
  my @file = <$fh>;
  
  close $fh;
	
  return \@file;
}

sub Write_File
{
  my ($filename, $output_r) = @_;
	
  open(my $fh, ">", $filename) or die "Can't read $filename: $!\n";
  
  map { print $fh "$_\n" } @$output_r;
  
  close $fh;
  
  return;
}

sub parse_VM_channels
{
  my ($filename) = @_;

  my $vm_listings_r = Read_File($filename);
	
  my $dom = Mojo::DOM->new;
	
  $dom->parse("@$vm_listings_r");

  # Extract 'id' data from <div> tags similiar to this:
  # <div style="-moz-user-select: none;" id="862 | BBC1 Sco" class="channel_row_name_two">

  my @tmp_array = map { $_->attrs->{id} } ($dom->find('div[class="channel_row_name_two"]')->each);

  my @channels = ();

  foreach my $el (@tmp_array)
  {
    my ($numID, $name) = split /\s+\|\s+/o, $el;

    (my $univ_name = uc($name)) =~ s/\s+//og;

    $channels[$numID] = {"Name", $name, "UnivName", $univ_name};
  }

  print "INFORMATION: Found ".scalar(@tmp_array)." channels from VM EPG\n";

  return @channels;
}

sub retrieve_XMLTV_channels
{
  my ($xmltv_output_r, $exit_status) = backticks_wrapper("$bash -c '$grabber --config-file $xmltv_config --list-channels 2> /dev/null'");

  my $dom = Mojo::DOM->new;

  $dom->parse("@$xmltv_output_r");
  
  my %tmp_hash = ();

  my @tmp_array = map {[$_->children('display-name'), $_->attrs->{id}]} ($dom->find('channel')->each);

  map { $_->[0] =~ s/<display-name>(.+)<\/display-name>/$1/o } (@tmp_array);

  foreach my $el (@tmp_array)
  {
    my ($name, $id1) = @$el;

    (my $univ_name = uc($name)) =~ s/\s+//og;
  
    $tmp_hash{$univ_name} = [$id1, $name];
  }

  print "INFORMATION: Found ".scalar(keys %tmp_hash)." channels from XMLTV Radio Times grabber\n";
  
  return %tmp_hash;
}

sub parse_myth_channels
{
	my ($input_file, $id_hash_r) = @_;

	my $mythchannels_r;
	my $exit_status;

	if (defined $input_file)
	{
		$mythchannels_r = Read_File($input_file);
	}
	else
	{
		($mythchannels_r, $exit_status) = backticks_wrapper("$wget -qO- http://$username:$password\@mythbox/mythweb/settings/tv/channels");

		if ($exit_status != 0)
		{
			print "\nERROR: wget of MythTV channel settings failed. Check Mythbox is up\n\n";
			exit;
		}
	}

	# Modified parsing of Myth channels to solve problem that suggested channels without a channel number
	# should be moved from an existing channel number rather than being given a new number.
	
	my $id = $num = undef;
	
	my $num_channels = 0;
	
	foreach my $line (@$mythchannels_r)
	{
		if ($line =~ /xmltvid.+value="([\S\.]+)"/o)
		{
			$id = $1;
			$num_channels++;
			
			$id_hash_r->{$id}[0] = (defined $id_hash{$id}[0] ? 0 : 1);
		}
		elsif ($line =~ /channum.+value="(\d+)"/o && defined $id)
		{
			$num = $1;
			
			$id_hash_r->{$id}[2] = $num;
		}
		elsif ($line =~ /<\/tr>/o)
		{
			$id = $num = undef;
		}
	}
	
	print "INFORMATION: $num_channels channels retrieved from Mythbox\n";

	return;
}

sub backticks_wrapper
{
        my @output = `$_[0]`;
        
        my $exit_status = $?;
        
        return (\@output, $exit_status);
}
