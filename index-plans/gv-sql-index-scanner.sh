#!/bin/bash

export SQLPATH=/home/oracle/working/still/sql

unset ORACLE_PATH
unset ORAENV_ASK

export PATH=/usr/local/bin/:$PATH

. /usr/local/bin/oraenv <<< emtprd02


: <<'JKS-DOC'

This script will run gv-sql-index-scanner.sql, which looks for the use of particular
index segments in gv$sql_plan

The query being run takes about 20 seconds

There does appear to be plenty of free mem in the shared_pool, so plans should not get removed from cache too frequently
At this time where are 3 week old plans in v$sql_plan

Running the query every 10 minutes should be sufficient

Each run is ~27k rows an 5M output

For 4 days  that is 576 executions :

15.5M Rows
2.8G output file

43G free space currently, so not a problem

JKS-DOC

_SQLPLUS=$ORACLE_HOME/bin/sqlplus

SLEEPTIME=600
SNAP_THRESHOLD=576
SNAPCOUNT=0

USERNAME=JSTILL

read -p 'password: ' -s PASSWORD
echo 

# test the logon

$_SQLPLUS -L $USERNAME/$PASSWORD <<-EOF
	select systimestamp from dual;
	exit;
EOF

sqlexit=$?


if [[ $sqlexit -eq 0 ]]; then
	echo Password checked OK
else
	echo Password Failed!
	exit $sqlexit
fi

cd /home/oracle/working/still/CR-1126608_indexes/plans/index-plans

while :
do

	(( SNAPCOUNT = SNAPCOUNT + 1 ))

	$_SQLPLUS /nolog <<-EOF
		connect jstill/${PASSWORD}
		@@gv-sql-index-scanner.sql
		exit
	EOF

	[ "$SNAPCOUNT" -ge "$SNAP_THRESHOLD" ] && exit

	sleep $SLEEPTIME

done

