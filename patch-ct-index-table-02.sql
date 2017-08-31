

@@get-schema &1

alter table &&u_schema..used_ct_index_sql add ( md5_hash varchar2(32));
create index &&u_schema..used_ct_index_sql_md5_idx on &&u_schema..used_ct_index_sql(md5_hash);

alter table &&u_schema..used_ct_index_sql_plan_pairs add ( md5_hash varchar2(32));
alter table &&u_schema..used_ct_index_sql_plan_pairs add ( force_matching_signature number);
create index &&u_schema..used_ct_index_md5_idx on &&u_schema..used_ct_index_sql_plan_pairs(md5_hash);
create index &&u_schema..used_ct_index_force_idx on &&u_schema..used_ct_index_sql_plan_pairs(force_matching_signature);


