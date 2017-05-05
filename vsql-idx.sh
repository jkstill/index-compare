#!/bin/bash


: <<'JKS-DOC'

We do not have access to AWR (dba_hist-*) or ASH (v$active_session_history)

Statspack is running but at level 5, so no sql plan data

The Perl script vsql-idx.pl will collect data from v$sql_plan.

All indexes owned by CT that appear in v$sql_plan will be recorded in a file created by the script

Each iteration will check for new entries as of the previous timestamp

JKS-DOC


# trap exits from parameter tests
trap "usage;exit 1" 0

usage () {
	echo
	echo
	echo usage: $0  oracle_home_SID database_name username schemaname
	echo " oracle_home_SID  : used to set environment with oraenv"
	echo " database_name    : db to connect to"
	echo " username         : user to connect as"
	echo " schemaname       : schema to check"
	echo
}

ORACLE_SID=$1
DB=$2
USERNAME=$3
SCHEMA=$4

# causes error exit if not set
: ${ORACLE_SID:?} ${DB:?} ${USERNAME:?} ${SCHEMA:?}

# turn off trap
trap 0

unset ORAENV_ASK

PATH=/usr/local/bin:$PATH

. /usr/local/bin/oraenv <<< $ORACLE_SID

# run every 5 minutes - 288 per day

maxIterations=144

# get the password

echo 
echo -n Enter the password for $USERNAME:
stty -echo
read PASSWORD
stty echo
echo
echo

trap -- '' SIGHUP

while ( [[ $maxIterations > 0 ]] )
do

	echo $PASSWORD | $ORACLE_HOME/perl/bin/perl vsql-idx.pl --database p1 --username jkstill --password --schema jkstill
	echo Iteration: $maxIterations
	sleep 300

	(( maxIterations-- ))
done >> vsql-idx_nohup.out &


