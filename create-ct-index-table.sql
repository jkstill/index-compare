

@@get-schema &1

create table &&u_schema..used_ct_indexes ( owner varchar2(30) not null, index_name varchar2(30) not null, primary key (owner,index_name) ) organization index
/

set echo off 


