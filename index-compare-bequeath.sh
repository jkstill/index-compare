#!/bin/bash


timestamp=$(date '+%Y%m%d-%H%M%S')

echo
echo This use assumes bequeath connection as SYSDBA
echo

echo "$ORACLE_HOME/perl/bin/perl ./index-compare.pl --sysdba --csv-file index-compare-${timestamp}.csv  | tee index-compare-${timestamp}.log"
echo

