#!/bin/bash


: <<'JKS-DOC'

We do not have access to AWR (dba_hist-*) or ASH (v$active_session_history)

Statspack is running but at level 5, so no sql plan data

The Perl script vsql-idx.pl will collect data from v$sql_plan.

All indexes owned by target schemas that appear in v$sql_plan will be recorded in a file created by the script

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
	echo
}

ORACLE_SID=$1
DB=$2
USERNAME=$3

# causes error exit if not set
: ${ORACLE_SID:?} ${DB:?} ${USERNAME:?} 

# turn off trap
trap 0

cat <<EOF

ORACLE_SID: $ORACLE_SID
DB: $DB
USERNAME: $USERNAME

EOF

unset ORAENV_ASK

PATH=/usr/local/bin:$PATH

. /usr/local/bin/oraenv <<< $ORACLE_SID

# run time is 2-3 minutes after the initial run of 10-15 minutes
# run every 10 minutes: ~110 per day

maxIterations=110

# get the password

echo 
echo -n Enter the password for $USERNAME:
stty -echo
read PASSWORD
stty echo
echo
echo

# create dir for csv files
mkdir -p csv

trap -- '' SIGHUP

while ( [[ $maxIterations > 0 ]] )
do

	echo $PASSWORD | $ORACLE_HOME/perl/bin/perl vsql-idx.pl --database $DB --username $USERNAME --password 
	echo Iteration: $maxIterations
	sleep 600

	(( maxIterations-- ))
done >> vsql-idx_nohup.out 2>&1 &


