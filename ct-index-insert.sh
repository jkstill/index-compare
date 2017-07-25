#!/bin/bash


: <<'JKS-DOC'

insert rows into avail.used_ct_indexes

These will be the namees of indexes we have found to be used

This script can be run multiple times to add new rows to the table as needed

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
	echo " schema           : schema were used_ct_indexes table is located"
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

# get the password


echo
echo -n Enter the password for $USERNAME:
stty -echo
read PASSWORD
stty echo
echo
echo


( tail -n +2 csv/vsql-idx.csv  | cut -f5-6 -d, | sort -u)  | $ORACLE_HOME/perl/bin/perl ct-index-insert.pl --database $DB --username $USERNAME --password $PASSWORD --schema $SCHEMA


