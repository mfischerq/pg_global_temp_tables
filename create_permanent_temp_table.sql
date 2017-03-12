﻿create or replace function create_permanent_temp_table(
	p_table_name varchar,
	p_schema varchar default null)
returns void as $$
declare
	v_table_name varchar := p_table_name || '$tmp';
	v_trigger_name varchar := p_table_name || '$iud';
	v_final_statement text;
	v_table_statement text; -- create temporary table...
	v_all_column_list text; -- id, name, ...
	v_new_column_list text; -- new.id, new.name, ...
	v_assignment_list text; -- id = new.id, name = new.name, ...
	v_cols_types_list text; -- id bigint, name varchar, ...
	v_old_column_list text; -- id = old.id
begin
	-- check if the temporary table exists
	if not exists(select 1 from pg_class where relname = p_table_name and relpersistence = 't') then
		raise exception 'Temporary table % does not exist.', p_table_name;
	end if;

	-- make sure that the schema is defined
	if p_schema is null or p_schema = '' then
		p_schema := current_schema;
	end if;

	-- generate the temporary table statement
	with pkey as
	(
		select cc.conrelid, format(E',
		constraint %I primary key(%s)', cc.conname,
			string_agg(a.attname, ', ' order by array_position(cc.conkey, a.attnum))) pkey
		from pg_catalog.pg_constraint cc
			join pg_catalog.pg_class c on c.oid = cc.conrelid
			join pg_catalog.pg_attribute a on a.attrelid = cc.conrelid and a.attnum = any(cc.conkey)
		where cc.contype = 'p'
		group by cc.conrelid, cc.conname
	)
	select format(E'\tcreate temporary table if not exists %I\n\t(\n%s%s\n\t)\n\ton commit drop;',
		v_table_name,
		string_agg(
			format(E'\t\t%I %s%s',
				a.attname,
				pg_catalog.format_type(a.atttypid, a.atttypmod),
				case when a.attnotnull then ' not null' else '' end
			), E',\n'
			order by a.attnum
		),
		(select pkey from pkey where pkey.conrelid = c.oid)) as sql
	into v_table_statement
	from pg_catalog.pg_class c
		join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
		join pg_catalog.pg_type t on a.atttypid = t.oid
	where c.relname = p_table_name and c.relpersistence = 't'
	group by c.oid, c.relname;

	-- generate the lists of columns
	select
		string_agg(a.attname, ', '),
		string_agg(format('new.%I', a.attname), ', '),
		string_agg(format('%I = new.%I', a.attname, a.attname), ', '),
		string_agg(format('%I %s', a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)), ', ')
	into
		v_all_column_list, v_new_column_list, v_assignment_list, v_cols_types_list
	from pg_catalog.pg_class c
		join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
		join pg_catalog.pg_type t on a.atttypid = t.oid
	where c.relname = p_table_name and c.relpersistence = 't';

	-- generate the list of primary key columns
	select string_agg(format('%I = old.%I', a.attname, a.attname), ' and ' 
		order by array_position(cc.conkey, a.attnum))
	into v_old_column_list
	from pg_catalog.pg_constraint cc
		join pg_catalog.pg_class c on c.oid = cc.conrelid
		join pg_catalog.pg_attribute a on a.attrelid = cc.conrelid and a.attnum = any(cc.conkey)
	where cc.contype = 'p' and c.relname = p_table_name and c.relpersistence = 't'
	group by cc.conrelid, cc.conname;

	-- generate the view function
	v_final_statement := format(E'-- rename the original table to avoid the conflict
alter table %I rename to %I;

-- the function to select from the temporary table 
create or replace function %I.%I() returns table(%s) as $x$
begin
	-- create table statement
%s

	return query select * from %I;
end;
$x$ language plpgsql 
set client_min_messages to error;\n',
	p_table_name, v_table_name,
	p_schema, p_table_name, v_cols_types_list,
	v_table_statement, v_table_name);

	-- generate the view
	v_final_statement := v_final_statement || format(E'
create or replace view %I.%I as 
	select * from %I.%I();\n',
	p_schema, p_table_name, p_schema, p_table_name);

	-- generate the trigger function
	v_final_statement := v_final_statement || format(E'
create or replace function %I.%I() returns trigger as $x$
begin
	-- create temporary table
%s

	-- handle the trigger operation
	if lower(tg_op) = \'insert\' then
		insert into %I(%s) 
		values (%s);
		return new;
	elsif lower(tg_op) = \'update\' then
		update %I 
		set %s
		where %s;
		return new;
	elsif lower(tg_op) = \'delete\' then
		delete from %I 
		where %s;
		return old;
	end if;
end;
$x$ language plpgsql set client_min_messages to error;\n',
	p_schema, v_trigger_name, v_table_statement, -- function header
	v_table_name, v_all_column_list, v_new_column_list, -- insert
	v_table_name, v_assignment_list, v_old_column_list, -- update
	v_table_name, v_old_column_list); -- delete

	-- generate the view trigger
	v_final_statement := v_final_statement || format(E'
drop trigger if exists %I on %I.%I;
create trigger %I 
	instead of insert or update or delete on %I.%I
	for each row
	execute procedure %I.%I();',
	v_trigger_name, p_schema, p_table_name,
	v_trigger_name, p_schema, p_table_name,
	p_schema, v_trigger_name);

	-- execute the statement
	execute v_final_statement;
end;
$$ language plpgsql;
