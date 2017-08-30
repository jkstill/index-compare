

@@get-schema &1

alter table &&u_schema..used_ct_index_sql add ( force_matching_signature number,	exact_matching_signature number );

create index &&u_schema..used_ct_index_sql_match_idx on &&u_schema..used_ct_index_sql(force_matching_signature);

 
