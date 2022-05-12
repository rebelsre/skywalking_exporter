#!/bin/bash
# 脚本功能:
#     skywalking 监控指标采集，输出为 exporter 格式
# 更新历史:
#     xxxx/xx/xx xxx 创建脚本
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

##### 变量区 #####
skywalking_api="https://xxx/graphql"
authorization="Basic xxx"
now=$(date -d "-8hour" "+%Y-%m-%d %H%M") # 当前时间减 8 小时，适配时区问题
a_minute_ago=$(date -d "-8hour-1min" "+%Y-%m-%d %H%M") # 当前时间减 8 小时 1 分钟
fifteen_minutes_ago=$(date -d "-8hour-15min" "+%Y-%m-%d %H%M") # 当前时间减 8 小时 15 分钟
get_all_services_query=$(cat get_all_services_query.gql)
service_query=$(cat service_query.gql)
delay_query=$(cat delay_query.gql)
get_all_services_variables=$(cat get_all_services_variables.template | sed -e "s/##START##/${fifteen_minutes_ago}/" -e "s/##END##/${now}/") # 间隔 15 分钟
service_cpm_variables=$(cat service_cpm_variables.template | sed -e "s/##START##/${fifteen_minutes_ago}/" -e "s/##END##/${now}/")
service_sla_variables=$(cat service_sla_variables.template | sed -e "s/##START##/${fifteen_minutes_ago}/" -e "s/##END##/${now}/")
service_resp_time_variables=$(cat service_resp_time_variables.template | sed -e "s/##START##/${fifteen_minutes_ago}/" -e "s/##END##/${now}/")
delay_variables=$(cat delay_variables.template | sed -e "s/##START##/${a_minute_ago}/" -e "s/##END##/${now}/") # 间隔 1 分钟

##### 函数区 #####
function get_all_services() { # 获取所有服务
    all_services=$(curl -s --location --request POST "${skywalking_api}" \
    --header "authorization: ${authorization}" \
    --header "Content-Type: application/json" \
    --data "{\"query\":\"${get_all_services_query}\",\"variables\":${get_all_services_variables}}" | grep -Po '(?<="label":")[^"]*(?=")') # cURL 请求 GraphQL 并截取 label 字段值
}

function service_cpm() { # 请求数
    local metrics="skywalking_service_cpm"
    cpm=$(curl -s --location --request POST "${skywalking_api}" \
    --header "authorization: ${authorization}" \
    --header "Content-Type: application/json" \
    --data "{\"query\":\"${service_query}\",\"variables\":${service_cpm_variables}}")
    echo "# TYPE ${metrics} gauge" # 输出 exporter 说明字段
    for service in $(echo "${cpm}" | grep -Po "{\"name\".*?}" | sort)
    do
        name=$(echo ${service} | grep -Po '(?<="name":")[^"]*(?=")')
        id=$(echo ${service} | grep -Po '(?<="id":")[^"]*(?=")')
        value=$(echo ${service} | grep -Po '(?<="value":")[^"]*(?=")')
        echo "${metrics}{service=\"${name}\",id=\"${id}\"} ${value}" # 输出符合 exporter 格式的监控指标及对应数值
    done
}

function service_sla() { # 成功率
    local metrics="skywalking_service_sla"
    sla=$(curl -s --location --request POST "${skywalking_api}" \
    --header "authorization: ${authorization}" \
    --header "Content-Type: application/json" \
    --data "{\"query\":\"${service_query}\",\"variables\":${service_sla_variables}}")
    echo "# TYPE ${metrics} gauge"
    for service in $(echo "${cpm}" | grep -Po "{\"name\".*?}" | sort)
    do
        name=$(echo ${service} | grep -Po '(?<="name":")[^"]*(?=")')
        id=$(echo ${service} | grep -Po '(?<="id":")[^"]*(?=")')
        value=$(echo ${service} | grep -Po '(?<="value":")[^"]*(?=")')
        echo "${metrics}{service=\"${name}\",id=\"${id}\"} ${value}"
    done
}

function service_resp_time() { # 平均时延
    local metrics="skywalking_service_resp_time"
    resp_time=$(curl -s --location --request POST "${skywalking_api}" \
    --header "authorization: ${authorization}" \
    --header "Content-Type: application/json" \
    --data "{\"query\":\"${service_query}\",\"variables\":${service_resp_time_variables}}")
    echo "# TYPE ${metrics} gauge"
    for service in $(echo "${cpm}" | grep -Po "{\"name\".*?}" | sort)
    do
        name=$(echo ${service} | grep -Po '(?<="name":")[^"]*(?=")')
        id=$(echo ${service} | grep -Po '(?<="id":")[^"]*(?=")')
        value=$(echo ${service} | grep -Po '(?<="value":")[^"]*(?=")')
        echo "${metrics}{service=\"${name}\",id=\"${id}\"} ${value}"
    done
}

function delay() { # P50/P75/P90/P95/P99 时延
    local metrics0="skywalking_p50_delay"
    local metrics1="skywalking_p75_delay"
    local metrics2="skywalking_p90_delay"
    local metrics3="skywalking_p95_delay"
    local metrics4="skywalking_p99_delay"
    local append="echo" # 配合 eval 追加变量
    get_all_services
    for service in ${all_services}
    do
        delay_new_variables=$(echo "${delay_variables}" | sed "s/##SERVICENAME##/${service}/") # 根据模板生成 GraphQL
        delay=$(curl -s --location --request POST "${skywalking_api}" \
        --header "authorization: ${authorization}" \
        --header "Content-Type: application/json" \
        --data "{\"query\":\"${delay_query}\",\"variables\":${delay_new_variables}}")
        intercept_data=$(echo "${delay}" | grep -Po "{\"label\".*?}.*?}") # 按 label 截取输出的两个数值
        for data in ${intercept_data}
        do
            label=$(echo ${data} | grep -Po "(?<=\"label\":\")[0-4](?=\")") # 获取 label 值，对应 Pxx 时延
            value=$(echo ${data} | grep -Po "(?<=\"value\":)[0-9]+(?=}$)") # 取两个数值中的第二个
            var=$(echo "$(eval echo \$metrics${label}){service=\"${service}\"} ${value}$") # 最后面的 $ 用来给 tr 进行换行
            append="${append} ${var}" # 配合 eval 追加变量
        done
    done
    # 追加变量并进行字段处理，输出符合 exporter 的格式
    # 在使用管道进行数据的输入输出时，所有的命令都是并行执行
    eval "${append}" |\
    tr "$" "\n" |\
    sed "s/^ //" |\
    sed "/^$/d" |\
    sed "s/service=/&\"/" |\
    sed "s/}/\"&/" |\
    sed "/${metrics0}.*/i${metrics0} gauge" |\
    sed "/${metrics1}.*/i${metrics1} gauge" |\
    sed "/${metrics2}.*/i${metrics2} gauge" |\
    sed "/${metrics3}.*/i${metrics3} gauge" |\
    sed "/${metrics4}.*/i${metrics4} gauge" |\
    sort -u |\
    sed "/gauge/s/^/# TYPE /"
}

##### 动作区 #####
get_all_services
service_cpm
service_sla
service_resp_time
delay
