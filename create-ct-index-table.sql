

@@get-schema &1

create table &&u_schema..used_ct_indexes (
	owner varchar2(30) not null,
	index_name varchar2(30) not null,
	primary key (owner,index_name)
) organization index
/

create table &&u_schema..used_ct_index_plans (
	plan_hash_value number not null,
	plan_text clob,
	primary key (plan_hash_value)
) organization index
/

create table &&u_schema..used_ct_index_sql (
	sql_id varchar2(13) not null,
	sql_text clob,
	force_matching_signature number,
	exact_matching_signature number,
	md5_hash varchar2(32),
	primary key (sql_id)
) organization index
/

create table &&u_schema..used_ct_index_sql_plan_pairs (
	owner varchar2(30) not null,
	index_name varchar2(30) not null,
	plan_hash_value number not null,
	sql_id varchar2(13) not null,
	force_matching_signature number,
	md5_hash varchar2(32),
	primary key (owner,index_name,plan_hash_value,sql_id)
) organization index
/

create index &&u_schema..used_ct_index_sql_match_idx on &&u_schema..used_ct_index_sql(force_matching_signature);
create index &&u_schema..used_ct_index_sql_md5_idx on &&u_schema..used_ct_index_sql(md5_hash);

create index &&u_schema..used_ct_index_sqlid_idx on &&u_schema..used_ct_index_sql_plan_pairs(sql_id);
create index &&u_schema..used_ct_index_plans_idx on &&u_schema..used_ct_index_sql_plan_pairs(plan_hash_value);
create index &&u_schema..used_ct_index_md5_idx on &&u_schema..used_ct_index_sql_plan_pairs(md5_hash);
create index &&u_schema..used_ct_index_force_idx on &&u_schema..used_ct_index_sql_plan_pairs(force_matching_signature);

alter table &&u_schema..used_ct_index_sql_plan_pairs add constraint sql_plan_pairs_parent_fk
foreign key (owner,index_name) 
references &&u_schema..used_ct_indexes (owner,index_name)
/

alter table &&u_schema..used_ct_index_sql_plan_pairs add constraint used_ct_index_sql_fk 
foreign key(sql_id)
references  &&u_schema..used_ct_index_sql(sql_id)
/

alter table &&u_schema..used_ct_index_sql_plan_pairs add constraint used_ct_index_plans_fk
foreign key(plan_hash_value)
references &&u_schema..used_ct_index_plans
/

set echo off 


