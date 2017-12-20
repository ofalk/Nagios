#!/bin/bash

#########################################################
#
#   Check state of IBM DS4x00 / 5x00 Health Status
#   
#   uses IBM SMclient package, tested with version 10.70 & 10.83 
#
#   created by Martin Moebius
#
#   05.10.2011 - 1.0 * initial version
#
#   28.11.2011 - 1.1 * added Status "Warning" instead of "Critical" in case of Preferred Path error
#                    * changed filtering of SMcli output to string based sed instead of position based awk
#                    * moved filtering of SMcli output to remove redundant code
#                    * more comments on code
#
#   06.02.2012 - 1.2 * added patch from user "cseres", better SMcli output parsing
#
#   03.09.2012 - 1.3 * filter controller clock sync warning from output
#
#   13.11.2012 - 1.4 * changed result parsing to fix "Unreadable sector" messages from DS3300/3400 not getting reported correctly
#
#   08.01.2012 - 1.5 * changed result parsing to fix "Battery Expiration" messages not getting reported correctly
#                    * added another wildcard entry in the nested "case"-statement to get at least a UNKNOWN response for any possible message
#
#########################################################

#SMcli location
COMMAND=/opt/IBM_DS/client/SMcli

# Define Nagios return codes
#
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3


#Help output
#
print_help() {

        echo ""
        echo "IBM DS4x00/5x00 Health Check"
        echo "the script requires IP of at least one DS4x00/5x00 Controller, second is optional"
        echo ""
        echo "Usage     check_IBM_health.sh -a X.X.X.X -b X.X.X.X"
        echo ""
        echo "          -h  Show this page"
        echo "          -a  IP of Controller A"
        echo "          -b  IP of Controller B"
        echo ""
    exit 0	
}

# Make sure the correct number of command line arguments have been supplied
#
if [ $# -lt 1 ]; then
    echo "At least one argument must be specified"
    print_help
    exit $STATE_UNKNOWN
fi

# Grab the command line arguments
#
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            print_help
            exit $STATE_OK
            ;;
        -a | --ctrla)
               shift
               CTRLA_IP=$1
                ;;
        -b | --ctrlb)
               shift
               CTRLB_IP=$1
               ;;
        *) 
               echo "Unknown argument: $1"
               print_help
               exit $STATE_UNKNOWN
            ;;
        esac
shift
done


# Check the health status via SMcli
#

##execute SMcli
RESULT=$($COMMAND $CTRLA_IP $CTRLB_IP -c "show storageSubsystem healthStatus;" -quick)

##filter unnecessary SMcli output
RESULT=$(echo $RESULT |sed 's/Performing syntax check...//g' | sed 's/Syntax check complete.//g' | sed 's/Executing script...//g' | sed 's/Script execution complete.//g'| sed 's/SMcli completed successfully.//g' | sed 's/The controller clocks in the storage subsystem are out of synchronization with the storage management station.//g' | sed 's/ Controller in Slot [AB]://g' | sed 's/Storage Management Station://g' | sed 's/\<[A-Za-z]\{3\}\>\s\<[A-Za-z]\{3\}\>\s[0-9]\{2\}\s[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\s\(CEST\|CET\)\s[0-9]\{4\}//g')

##check SMcli output to identfy error and report back to Nagios
case "$RESULT" in
 *optimal*)
  echo $RESULT
  echo "OK"
  exit $STATE_OK
  ;;
 *failure*)
  case "$RESULT" in
    *failed*|*Failed*|*Unreadable*)
      echo $RESULT
      echo "CRITICAL"
      exit $STATE_CRITICAL
    ;;
    *preferred*|*Preferred*|*Expiration*)
      echo $RESULT
      echo "WARNING"
      exit $STATE_WARNING
    ;;
    *)
     echo "Unkown response from SMcli: \" $RESULT \""
     echo "UNKNOWN"
     exit $STATE_UNKNOWN
    ;;
  esac
  ;;
 *)
  echo "Unkown response from SMcli: \" $RESULT \""
  echo "UNKNOWN"
  exit $STATE_UNKNOWN
 ;;
esac
