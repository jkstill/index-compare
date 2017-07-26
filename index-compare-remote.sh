#!/bin/bash


timestamp=$(date '+%Y%m%d-%H%M%S')

echo
echo This use assumes remote connection as SYSDBA
echo
echo the --password invokes a prompt for password
echo

echo "$ORACLE_HOME/perl/bin/perl index-compare.pl --database orcl -username scott --password --sysdba --csv-file index-compare-${timestamp}.csv  | tee index-compare-${timestamp}.log"
echo

