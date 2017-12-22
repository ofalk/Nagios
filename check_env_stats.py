#! /usr/bin/python
#
# Copyright (c) Brady Lamprecht
# Licensed under GPLv3
# March 2009
#
# check_env_stats plug-in for nagios
# Uses SNMP to poll for voltage, temerature, fan, and power supply statistics
#
# History:
#
# v0.1 Very basic script to poll given SNMP values (Foundry only)
# v0.2 Added functionality for temperature, fans, power supplies
# v0.3 Included Cisco support with the addition of voltage
# v0.4 Functions to set warning and critical levels were added
# v0.5 Now implements "-p" perfmon option for performance data
# v1.0 Code cleanup and a few minor bugfixes

import os
import sys
from optparse import OptionParser

scriptversion = "1.0"

errors = {
    "OK": 0,
    "WARNING": 1,
    "CRITICAL": 2,
    "UNKNOWN": 3,
    }

common_options = "snmpwalk -OvQ -v 1"

# Function for Cisco equipment
def check_cisco(hostname,community,mode,verbose):
    command = common_options + " -c " + community + " " + hostname + " "
    ciscoEnvMonObjects = "1.3.6.1.4.1.9.9.13.1"

    if mode == "volt":
        ciscoVoltDescTable = ciscoEnvMonObjects + ".2.1.2"
        ciscoVoltValuTable = ciscoEnvMonObjects + ".2.1.3"
        desc = os.popen(command + ciscoVoltDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + ciscoVoltValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
            print_verbose(ciscoVoltDescTable,desc,ciscoVoltValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
        return(desc,valu)

    if mode == "temp":
        ciscoTempDescTable = ciscoEnvMonObjects + ".3.1.2"
        ciscoTempValuTable = ciscoEnvMonObjects + ".3.1.3"
        desc = os.popen(command + ciscoTempDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + ciscoTempValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
            print_verbose(ciscoTempDescTable,desc,ciscoTempValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
        return(desc,valu)

    if mode == "fans":
        # Possible values:
        # 1=normal,2=warning,3=critical,4=shutdown,5=notPresent,6=notFunctioning
        ciscoFansDescTable = ciscoEnvMonObjects + ".4.1.2"
        ciscoFansValuTable = ciscoEnvMonObjects + ".4.1.3"
        desc = os.popen(command + ciscoFansDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + ciscoFansValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
            print_verbose(ciscoFansDescTable,desc,ciscoFansValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
        return(desc,valu)

    if mode == "power":
        # Possible values:
        # 1=normal,2=warning,3=critical,4=shutdown,5=notPresent,6=notFunctioning
        ciscoPowrDescTable = ciscoEnvMonObjects + ".5.1.2"
        ciscoPowrValuTable = ciscoEnvMonObjects + ".5.1.3"
        desc = os.popen(command + ciscoPowrDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + ciscoPowrValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
            print_verbose(ciscoPowrDescTable,desc,ciscoPowrValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
	return(desc,valu)

    # Should never get to here
    sys.exit(errors['UNKNOWN'])

# Function for Foundry equipment
def check_foundry(hostname,community,mode,verbose):
    command = common_options + " -c " + community + " " + hostname + " "
    foundrySNAgent = "1.3.6.1.4.1.1991.1.1"

    if mode == "volt":
        fail("voltage table does not exist in Foundry's MIB.")

    if mode == "temp":
        foundryTempDescTable = foundrySNAgent + ".2.13.1.1.3"
        foundryTempValuTable = foundrySNAgent + ".2.13.1.1.4"
        desc = os.popen(command + foundryTempDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + foundryTempValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
            print_verbose(foundryTempDescTable,desc,foundryTempValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
        return(desc,valu)

    if mode == "fans":
        # Possible values:
        # 1=other,2=normal,3=critical
        foundryFansDescTable = foundrySNAgent + ".1.3.1.1.2"
        foundryFansValuTable = foundrySNAgent + ".1.3.1.1.3"
        desc = os.popen(command + foundryFansDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + foundryFansValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
            print_verbose(foundryFansDescTable,desc,foundryFansValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
        return(desc, valu)

    if mode == "power":
        # Possible values:
        # 1=other,2=normal,3=critical
        foundryPowrDescTable = foundrySNAgent + ".1.2.1.1.2"
        foundryPowrValuTable = foundrySNAgent + ".1.2.1.1.3"
        desc = os.popen(command + foundryPowrDescTable).read()[:-1].replace('\"', '').split('\n')
        valu = os.popen(command + foundryPowrValuTable).read()[:-1].replace('\"', '').split('\n')
        if verbose:
             print_verbose(foundryPowrDescTable,desc,foundryPowrValuTable,valu)
        if desc[0] == '' or valu[0] == '':
            fail("description / value table empty or non-existent.")
        return(desc,valu)

    # Should never get to here
    sys.exit(errors['UNKNOWN'])

# Function for HP equipment
def check_hp(hostname,community,mode,verbose):
    fail("HP functions not yet implemented.")

# Function for Juniper equipment
def check_juniper(hostname,community,mode,verbose):
    fail("Juniper functions not yet implemented.")

# Function to process data from SNMP tables
def process_data(description, value, warning, critical, performance):
    string = ""
    status = "OK"
    perfstring = ""

    if critical and warning:
        if len(critical) != len(description):
            fail("number of critical values not equal to number of table values.")
        elif len(warning) != len(description):
            fail("number of warning values not equal to number of table values.")
        else:
	
            # Check for integer or string values

            # Check each table value against provided warning & critical values
            for d, v, w, c in zip(description,value,warning,critical):
                if len(string) != 0:
                    string += ", "
                if v >= c:
                    status = "CRITICAL"
                    string += d + ": " + str(v) + " (C=" + str(c) + ")"
                elif v >= w:
                    if status != "CRITICAL":
                        status = "WARNING"
                    string += d + ": " + str(v) + " (W=" + str(w) + ")"
                else:
                    string += d + ": " + str(v)

                # Create performance data
                perfstring += d.replace(' ', '_') + "=" + str(v) + " "

    # Used to provide output when no warning & critical values are provided
    else:
         for d, v in zip(description,value):
             if len(string) != 0:
                  string += ", "
             string += d + ": " + str(v)
             
             # Create performance data
             perfstring += d.replace(' ', '_') + "=" + str(v) + " "

    # If requested, include performance data
    if performance:
        string += " | " + perfstring

    # Print status text and return correct value.
    print status + ": " + string
    sys.exit(errors[status])

def print_verbose(oid_A,val_A,oid_B,val_B):
    print "Description Table:\n\t" + str(oid_A) + " = \n\t" + str(val_A)
    print "Value Table:\n\t" + str(oid_B) + " = \n\t" + str(val_B)
    sys.exit(errors['UNKNOWN'])

def fail(message):
    print "Error: " + message	
    sys.exit(errors['UNKNOWN'])

def main():
    args = None
    options = None	

    # Create command-line options
    parser = OptionParser(version="%prog " + scriptversion)
    parser.add_option("-H", action="store", type="string", dest="hostname", help="hostname or IP of device")
    parser.add_option("-C", action="store", type="string", dest="community", help="community read-only string [default=%default]", default="public")
    parser.add_option("-T", action="store", type="string", dest="type", help="hardware type (cisco,foundry,hp,juniper)")
    parser.add_option("-M", action="store", type="string", dest="mode", help="type of statistics to gather (temp,fans,power,volt)")
    parser.add_option("-w", action="store", type="string", dest="warn", help="comma-seperated list of values at which to set warning")
    parser.add_option("-c", action="store", type="string", dest="crit", help="comma-seperated list of values at which to set critical")
    parser.add_option("-p", action="store_true", dest="perf", help="include perfmon output")
    parser.add_option("-v", action="store_true", dest="verb", help="enable verbose output")
    (options, args) = parser.parse_args(args)

    # Map parser values to variables
    host = options.hostname
    comm = options.community
    type = options.type
    mode = options.mode
    warn = options.warn
    if warn:
        warn = map(int,options.warn.split(','))
    crit = options.crit
    if crit:
        crit = map(int,options.crit.split(','))
    perf = options.perf
    verb = options.verb

    # Check for required "-H" option
    if host:
        pass
    else:
        fail("-H is a required argument")

    # Check for required "-M" option and verify value is supported
    if mode:
        if mode == "temp" or mode == "fans" or mode == "power" or mode == "volt":
            pass
        else:
            fail("-M only supports modes of temp, fans, power, volt")
    else:
        fail("-M is a required argument")

    # Check for required "-T" option
    if type:
        pass
    else:
        fail("-T is a required argument")

    # Check for valid "-T" option and execute appropriate check
    if type == "cisco": 
        (desc, value) = check_cisco(host,comm,mode,verb)
        process_data(desc, map(int,value), warn, crit, perf)
    if type == "foundry": 
        (desc, value) = check_foundry(host,comm,mode,verb)
        process_data(desc, map(int,value), warn, crit, perf)
    if type == "hp":
        (desc, value) = check_hp(host,comm,mode,verb)
        process_data(desc, map(int,value), warn, crit, perf)
    if type == "juniper":
        (desc, value) = check_juniper(host,commu,mode,verb)
        process_data(desc, map(int,value), warn, crit, perf)
    else:
        fail("-T only supports types of cisco, foundry, hp, or juniper") 

    # Should never get here
    sys.exit(errors['UNKNOWN'])

# Execute main() function
if __name__ == "__main__":
	main()
