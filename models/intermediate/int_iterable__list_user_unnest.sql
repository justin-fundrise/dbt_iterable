{{ config(materialized='table',
            unique_key='unique_key',
            incremental_strategy='insert_overwrite' if target.type in ('bigquery', 'spark', 'databricks') else 'delete+insert',
            file_format='delta'
        ) 
}}
-- materializing as a table because the computations here are fairly complex

with user_history as (

    select * 
    from {{ ref('int_iterable__list_user_history') }} as user_history

    {% if is_incremental() %}
    where user_history.updated_at >= coalesce((select max({{this}}.updated_at) from {{ this }}), '1900-01-01')
    {% endif %}

{% if target.type == 'redshift' %}
), redshift_parse_email_lists as (

    select
        email,
        first_name,
        last_name,
        user_id,
        signup_date,
        signup_source,
        phone_number,
        updated_at,
        is_current,
        email_list_ids,
        json_parse(case when email_list_ids = '[]' then '["is_null"]' else email_list_ids end) as super_email_list_ids
        
    from user_history

), unnest_email_array as (

    select
        email,
        first_name,
        last_name,
        user_id,
        signup_date,
        signup_source,
        phone_number,
        updated_at,
        is_current,
        cast(email_list_ids as {{ dbt.type_string() }}) as email_list_ids,
        cast(email_list_id as {{ dbt.type_string() }}) as email_list_id

    from redshift_parse_email_lists as emails, emails.super_email_list_ids as email_list_id

{% else %}

), unnest_email_array as (

    select
        email,
        first_name,
        last_name,
        user_id,
        signup_date,
        signup_source,
        phone_number,
        updated_at,
        is_current,
        email_list_ids,
        case when email_list_ids != '[]' then
        {% if target.type == 'snowflake' %}
        email_list_id.value
        {% else %} email_list_id
        {% endif %}
        else null end 
        as 
        email_list_id

    from user_history

    {% if target.type == 'snowflake' %}
    cross join 
        table(flatten(cast(email_list_ids as VARIANT))) as email_list_id 
    {% elif target.type == 'bigquery' %}
    cross join 
        unnest(JSON_EXTRACT_STRING_ARRAY(email_list_ids)) as email_list_id
    {% else %}
    /* postgres */
    cross join 
        json_array_elements_text(cast((
            case when email_list_ids = '[]' then '["is_null"]'  -- to not remove empty array-rows
            else email_list_ids end) as json)) as email_list_id
    {%- endif %}

{%- endif -%}
), adjust_nulls as (

    select
        email,
        first_name,
        last_name,
        user_id,
        signup_date,
        signup_source,
        updated_at,
        phone_number,
        is_current,
        case when email_list_ids = '["is_null"]' then '[]' else email_list_ids end as email_list_ids,
        cast(NULLIF(email_list_id, 'is_null') as {{ dbt.type_int() }}) as list_id

    from unnest_email_array

), final as (

    select
        email,
        first_name,
        last_name,
        user_id,
        signup_date,
        signup_source,
        updated_at,
        phone_number,
        is_current,
        email_list_ids,
        list_id,
        {{ dbt_utils.generate_surrogate_key(["email", "list_id", "updated_at"]) }} as unique_key
    
    from adjust_nulls
)

select *
from final