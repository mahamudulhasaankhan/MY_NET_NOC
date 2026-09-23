sql {
    dialect = "postgresql"
    driver = "rlm_sql_postgresql"

    postgresql {
        send_application_name = yes
    }

    server = "postgres"
    port = 5432
    login = "${PG_USERNAME}"
    password = "${PG_PASSWORD}"
    radius_db = "${PG_DATABASE}"

    acct_table1 = "radacct"
    acct_table2 = "radacct"
    postauth_table = "radpostauth"
    authcheck_table = "radcheck"
    groupcheck_table = "radgroupcheck"
    authreply_table = "radreply"
    groupreply_table = "radgroupreply"
    usergroup_table = "radusergroup"

    delete_stale_sessions = yes

    pool {
        start = 5
        min = 5
        max = 20
        spare = 5
        uses = 0
        retry_delay = 30
        lifetime = 0
        idle_timeout = 60
        max_retries = 5
    }

    group_attribute = "SQL-Group"

    read_clients = yes
    client_table = "nas"

    $INCLUDE ${modconfdir}/${.:name}/main/${dialect}/queries.conf
}
