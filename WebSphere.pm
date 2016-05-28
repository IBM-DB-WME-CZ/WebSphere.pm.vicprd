package WebSphere;
# $Id: WebSphere.pm,v 1.13 2011/04/12 14:56:03 xtrnshv Exp $
#----------------------------------------------
# Copyright: (c) IBM Business Services
# Author: Radoslaw Wierzbicki
#----------------------------------------------
#

use strict;
use CommonLogger;
use Defaults;
use Tools;
use CellConfig;
use Executing;
use FindBin qw($Bin);
use WAS;
use WASas;
use WASnd;
use WAS61;
use WASas61;
use WASnd61;
use WASas70;
use WASnd70;
use Const;
use Time::Local 'timelocal_nocheck';

our $VERSION = "1.10";

##############################
#
sub get_cellconfig_location {
	my $cell_name = shift;
	return get_default('path_var_product') . "/$cell_name/config/" . get_default('file_cellconfig');
}

##############################
#
sub get_cellconfig {
	my $cell_name       = shift;
	my $cell_config_xml = get_cellconfig_location($cell_name);

	if (-e $cell_config_xml) {
		return new CellConfig($cell_config_xml);
	} else {
		return undef;
	}
}

##############################
# create and return object depending on product_fn, subproduct_fn and version
#  (e.g. was60, was60_nd, was61, was61_nd, etc.)
# return undef if such object cannot be created
#
sub get_object_from_version {
	my $version_name = shift;
	my $product;
	my $version;
	my $product_fn;
	my $was = undef;
	my $subproduct_fn;
	my $was_object;

	logthis(DEBUG, (caller(0))[0] . ":" . (caller(0))[3] . " BEGIN");

	#Defaults::read_defaults_xml("$Bin/defaults.xml");

	$product       = get_default("product");
	$product_fn    = get_default("product_fn");
	$subproduct_fn = get_default("DM/subproduct_fn");

	if ($version_name =~ /^${product_fn}(\d{2})(?:_32|_64)?$/) {
		$version = $1;

		if ($version eq "60") {
			$was_object = "WASas";
		} else {
			$was_object = "WASas$version";
		}		
		$was = new $was_object("$Bin/defaults.xml");
	} elsif ($version_name =~ /^$product_fn(\d{2})$subproduct_fn(?:_32|_64)?$/) {
		$version = $1;

		if ($version eq "60") {
			$was_object = "WASnd";
		} else {
			$was_object = "WASnd$version";
		}
		$was = new $was_object("$Bin/defaults.xml");
	} else {
		logthis(ERROR, "'$version_name' is not supported!");
	}

	return $was;
}

##############################
# create and return object depending on product (DM or AS) and hostname.
# return undef if such object cannot be created
#
sub get_object_from_cellname {
	my $cell_name   = shift;
	my $object_type = shift;
	my $was_version;
	my $cellconfig;
	my $was = undef;
	my $was_object;
	my $version_string;
	my $hostname = Tools::get_hostname();

	logthis(DEBUG, (caller(0))[3] . " ($cell_name) ($object_type) BEGIN");
	die "'object_type' must be specified!" if (!defined($object_type));

	$cellconfig = get_cellconfig($cell_name);
	if (!defined($cellconfig)) {
		return $was;
	}

	$was_version = $cellconfig->get_was_version();
	$was_version =~ /(\d)\.(\d)/;
	$version_string = "$1$2";

	if ($object_type == DM) {
		# create and return new WASnd object only if a dmgr is
		# defined for the current host
		if ($version_string eq "60") {
			$was_object = "WASnd";
		} else {
			$was_object = "WASnd$version_string";
		}
		if ($cellconfig->is_dmgr_defined($hostname)) {
			my $interface = $cellconfig->get_value("manager/dmgr/var/INTERFACE");
			if (interface_online_on_curr_machine($interface)) {
				$was = new $was_object("$Bin/defaults.xml");
			} else {
				my $num_hosts = $cellconfig->get_dmgr_num_hosts();
				
				if($num_hosts == 1) {
					# the dmgr is defined on only one host, but the defined interface
					# is either offline or wrong -> error	
					die "dmgr interface '$interface' doesn't exist!";
				}
			}
		}
	} elsif ($object_type == AS) {
		my $host_servers = $cellconfig->get_all_servers($hostname);
		# create and return new WASas object only if at least one
		# app server is defined for the current host

		if ($version_string eq "60") {
			$was_object = "WASas";
		} else {
			$was_object = "WASas$version_string";
		}

		if (scalar @$host_servers > 0) {
			# here we are using always the first defined server ($host_servers[0]) because
			# all servers should have the same interface (the script doesn't check that)
			my $interface = $cellconfig->get_value("server/".@$host_servers[-1]."/var/INTERFACE");

			if (interface_online_on_curr_machine($interface)) {
				$was = new $was_object("$Bin/defaults.xml");
			} else {
				my $num_hosts = $cellconfig->get_server_num_hosts(@$host_servers[-1]);
				
				if($num_hosts == 1) {
					# server $host_servers[-1] is defined on only one host, 
					# but the defined interface
					# is either offline or wrong -> error	
					die "server interface '$interface' doesn't exist!";
				}
			}
		}
	} else {
		logthis(ERROR, "Unknown object type '$object_type'!");
	}

	if (defined($was)) {
		logthis(DEBUG, "Created new WAS object: $was");
		$was->set_active_cell($cell_name);
	}
	return $was;
}

##############################
#
sub get_object_name {
	my $object_type = shift;

	if ($object_type == DM) {
		return "DM";
	} elsif ($object_type == AS) {
		return "AS";
	} else {
		die "unknown object type: $object_type";
	}
}

#####################################################################
#
sub generate_node_name {
	my $hostname = shift;

	return (split(/\./, $hostname))[0] . "_Node";
}

##############################
# Adding the groups CellConfig.xml/<GROUPS> to the $exec_user
#
sub chgroup {
	my $exec_user  = get_exec_user();
	my $exec_group = get_exec_group();
	my ($new_groups, $old_groups);
	my (@new_groups_arr, @old_groups_arr, @to_add_groups);

	if (Tools::OSName ne 'AIX') {
		return 1;
	}
	return 0 if (!defined($new_groups = CellConfig::get_value("var/GROUPS")));
	@new_groups_arr = split(/,/, $new_groups);
	$old_groups = @{Executing::fork_and_read("groups $exec_user")}[0];
	$old_groups =~ s/.+:\s*//;
	@old_groups_arr = split(/\s+/, $old_groups);

	foreach my $grp (@new_groups_arr) {
		my @tmp = grep /$grp/, @old_groups_arr;
		if (scalar(grep(/$grp/, @old_groups_arr)) == 0) {
			push @to_add_groups, $grp;
		}
	}
	return 0 if ($#to_add_groups == -1);

	$new_groups = join(',', @old_groups_arr) . "," . join(',', @to_add_groups);
	logthis(INFO, "Adding the group(s) '$new_groups' to user '$exec_user'");

	my $res = Executing::fork_and_print("chuser groups=$new_groups $exec_user");
	return $res if ($res);

	return 0;
}

#####################################################################
#
sub unstash {
	my $stashfile = shift;

	my $fh = new IO::File("<$stashfile");
	if (!$fh) {
		logthis(ERROR, "unstash(): Could not open input file $stashfile");
		return undef;
	}

	local $/;
	my $content = <$fh>;
	$fh->close();

	# =8->
	my $result = pack("C*", map {$_ ^ 0xf5} unpack("C*", $content));
	return substr($result, 0, index($result, chr(0)));
}

#####################################################################
# return true(1) if $interface is online on the current machine, else false
#
sub interface_online_on_curr_machine {
	my $interface = shift;
	my $ip        = nslookup($interface);
	my $ip_online = 0;

	if (defined($ip)) {
		logthis(DEBUG, "interface(ip): $interface($ip)");
	} else {
		logthis(DEBUG, "interface(ip): $interface(undef)");		
	}
	return $ip_online if (!defined($ip));

	# check, if the defined $interface is online on the current machine, because:
	# 1. it could be wrong
	# 2. it could be cluster interface, which is online on the other cluster counterpart
	#
	$ip_online = ip_online_on_curr_machine($ip);
	logthis(DEBUG, "$interface($ip) : $ip_online");

	return $ip_online;
}

#####################################################################
#
sub nslookup {
	my $interface = shift;
	my $name_fl   = 0;
	my $ip        = undef;

	logthis(DEBUG, "nslookup() interface:$interface");
	
	return $ip if (!defined($interface));
	
	open NSL, "/usr/bin/nslookup $interface 2>&1 |";
	while (<NSL>) {
                if (/$interface\s*canonical\s*name\s*=\s*(.+)\./) {
                        $interface = $1;
                }
		if (/Name:\s*$interface/) {
			$name_fl = 1;
		}
		if ($name_fl && /Address:\s*(.+)/) {
			$ip = $1;
			last;
		}
	}
	close NSL;

	return $ip;
}

#####################################################################
#
sub ip_online_on_curr_machine {
	my $ip        = shift;
	my $ip_online = 0;

	open IF, "/etc/ifconfig -a|grep $ip|";
	while (<IF>) {
		if (/$ip/) {
			$ip_online = 1;
			last;
		}
	}
	close IF;

	return $ip_online;
}

##############################
1;
