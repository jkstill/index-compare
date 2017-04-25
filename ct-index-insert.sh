#!/bin/bash


: <<'JKS-DOC'

insert rows into avail.used_ct_indexes

These will be the namees of indexes we have found to be used

This script can be run multiple times to add new rows to the table as needed

JKS-DOC

IDXHOME='/home/oracle/working/still/CR-1113105_indexes'

cd $IDXHOME || {
	echo
	echo $IDXHOME not found
	exit 1
}


unset ORAENV_ASK

PATH=/usr/local/bin:$PATH

. /usr/local/bin/oraenv <<< iotkdb


(cut -f5 -d, vsql-idx.csv | sort -u)  | $ORACLE_HOME/perl/bin/perl ct-index-insert.pl

