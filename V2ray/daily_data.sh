unifyUnit(){
    if (( $1 == 'KB'));then
        return $1
    elif (( $1 == 'MB'));then
        return 
}


curDate=$(date "+%Y-%m-%d")
curMonth=$(date "+%Y-%m")
last_day_s=$(( $(date +%s) - 86000 ))
last_day=$(date -d @$last_day_s "+%Y-%m-%d")


cat traffic.txt | grep user | awk -F'[ :]+|->' '{print "[""'$curDate'""]",$2, $3, $4}' >> $curMonth.txt

todayData=$(cat $curMonth.txt | grep $curDate)
lastDayData=$(cat $curMonth.txt | grep $last_day)

for data in $todayData
do
user=$(echo $data | awk '{print $2, $3}')
user_data=$(echo $data | awk '{print $4}')
last_day_data=$(echo $lastDayData | grep $user | awk '{print $4}')
done

unset curDate
