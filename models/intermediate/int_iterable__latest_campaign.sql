with campaign_history as (
  select *
  from {{ var('campaign_history') }}

), latest_campaign as (
    select
      *,
      row_number() over(partition by campaign_id order by updated_at desc) as latest_campaign_index
    from campaign_history
)

select *
from latest_campaign
where latest_campaign_index = 1