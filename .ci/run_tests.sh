#!/usr/bin/env bash
set -e

ulimit -c unlimited
mkdir -p /tmp/cores
chmod 777 /tmp/cores
echo '/tmp/cores/core.%e.%p' | sudo tee /proc/sys/kernel/core_pattern
sudo sysctl -w fs.suid_dumpable=2
sudo sysctl -p

function cyan() {
    echo -e "\033[1;36m$*\033[0m"
}
function red() {
    echo -e "\033[1;31m$*\033[0m"
}

export BUSTED_ARGS="--no-k -o htest -v --exclude-tags=flaky,ipv6"

if [ "$KONG_TEST_DATABASE" == "postgres" ]; then
    export TEST_CMD="bin/busted $BUSTED_ARGS,off"

    psql -v ON_ERROR_STOP=1 -h localhost --username "$KONG_TEST_PG_USER" <<-EOSQL
        CREATE user ${KONG_TEST_PG_USER}_ro;
        GRANT CONNECT ON DATABASE $KONG_TEST_PG_DATABASE TO ${KONG_TEST_PG_USER}_ro;
        \c $KONG_TEST_PG_DATABASE;
        GRANT USAGE ON SCHEMA public TO ${KONG_TEST_PG_USER}_ro;
        ALTER DEFAULT PRIVILEGES FOR ROLE $KONG_TEST_PG_USER IN SCHEMA public GRANT SELECT ON TABLES TO ${KONG_TEST_PG_USER}_ro;
EOSQL

elif [ "$KONG_TEST_DATABASE" == "cassandra" ]; then
  echo "Cassandra is no longer supported"
  exit 1

else
    export TEST_CMD="bin/busted $BUSTED_ARGS,postgres,db"
fi

if [[ "$KONG_TEST_COVERAGE" = true ]]; then
    export TEST_CMD="$TEST_CMD --keep-going"
fi

if [ "$TEST_SUITE" == "integration" ]; then
    if [[ "$TEST_SPLIT" == first* ]]; then
        # GitHub Actions, run first batch of integration tests
        eval "$TEST_CMD" $(ls -d spec/02-integration/* | sort | grep -v 05-proxy)

    elif [[ "$TEST_SPLIT" == second* ]]; then
        # GitHub Actions, run second batch of integration tests
        # Note that the split here is chosen carefully to result
        # in a similar run time between the two batches, and should
        # be adjusted if imbalance become significant in the future
        eval "$TEST_CMD" $(ls -d spec/02-integration/* | sort | grep 05-proxy)

    else
        # Non GitHub Actions
        eval "$TEST_CMD" spec/02-integration/
    fi
fi

if [ "$TEST_SUITE" == "dbless" ]; then
    eval "$TEST_CMD" spec/02-integration/02-cmd \
                     spec/02-integration/05-proxy \
                     spec/02-integration/04-admin_api/02-kong_routes_spec.lua \
                     spec/02-integration/04-admin_api/15-off_spec.lua \
                     spec/02-integration/08-status_api/01-core_routes_spec.lua \
                     spec/02-integration/08-status_api/03-readiness_endpoint_spec.lua \
                     spec/02-integration/11-dbless
fi
if [ "$TEST_SUITE" == "plugins" ]; then
    set +ex
    rm -f .failed

    if [[ "$TEST_SPLIT" == first* ]]; then
        # GitHub Actions, run first batch of plugin tests
        PLUGINS=$(ls -d spec/03-plugins/* | head -n22)

    elif [[ "$TEST_SPLIT" == second* ]]; then
        # GitHub Actions, run second batch of plugin tests
        # Note that the split here is chosen carefully to result
        # in a similar run time between the two batches, and should
        # be adjusted if imbalance become significant in the future
        PLUGINS=$(ls -d spec/03-plugins/27-aws-lambda*)

    else
        # Non GitHub Actions
        PLUGINS=$(ls -d spec/03-plugins/*)
    fi

    for p in $PLUGINS; do
        echo
        cyan "--------------------------------------"
        cyan $(basename $p)
        cyan "--------------------------------------"
        echo

        $TEST_CMD $p || echo "* $p" >> .failed
    done

    if [[ "$TEST_SPLIT" == second* ]] || [[ "$TEST_SPLIT" != first* ]]; then
        cat kong-*.rockspec | grep kong- | grep -v zipkin | grep -v sidecar | grep "~" | grep -v kong-prometheus-plugin | while read line ; do
            REPOSITORY=`echo $line | sed "s/\"/ /g" | awk -F" " '{print $1}'`
            VERSION=`luarocks show $REPOSITORY | grep $REPOSITORY | head -1 | awk -F" " '{print $2}' | cut -f1 -d"-"`
            REPOSITORY=`echo $REPOSITORY | sed -e 's/kong-prometheus-plugin/kong-plugin-prometheus/g'`
            REPOSITORY=`echo $REPOSITORY | sed -e 's/kong-proxy-cache-plugin/kong-plugin-proxy-cache/g'`

            echo
            cyan "--------------------------------------"
            cyan $REPOSITORY $VERSION
            cyan "--------------------------------------"
            echo

            git clone https://github.com/Kong/$REPOSITORY.git --branch $VERSION --single-branch /tmp/test-$REPOSITORY || \
            git clone https://github.com/Kong/$REPOSITORY.git --branch v$VERSION --single-branch /tmp/test-$REPOSITORY
            sed -i 's/grpcbin:9000/localhost:15002/g' /tmp/test-$REPOSITORY/spec/*.lua
            sed -i 's/grpcbin:9001/localhost:15003/g' /tmp/test-$REPOSITORY/spec/*.lua
            cp -R /tmp/test-$REPOSITORY/spec/fixtures/* spec/fixtures/ || true
            pushd /tmp/test-$REPOSITORY
            luarocks make
            popd

            $TEST_CMD /tmp/test-$REPOSITORY/spec/ || echo "* $REPOSITORY" >> .failed

        done
    fi

    if [ -f .failed ]; then
        echo
        red "--------------------------------------"
        red "Plugin tests failed:"
        red "--------------------------------------"
        cat .failed
        exit 1
    else
        exit 0
    fi
fi
if [ "$TEST_SUITE" == "pdk" ]; then
    prove -I. -r t
fi
if [ "$TEST_SUITE" == "unit" ]; then
    unset KONG_TEST_NGINX_USER KONG_PG_PASSWORD KONG_TEST_PG_PASSWORD
    scripts/autodoc
    bin/busted -v -o htest spec/01-unit
    make lint
fi