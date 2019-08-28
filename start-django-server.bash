#!/bin/bash

# Author: Shadowwolf (xshadowwolfx1996@gmail.com)
# Description: A script for django + nginx + supervisor
# + gunicorn deployment. 

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

user_exist=0
group_exist=0

if [ ! "$BASH_VERSION" ]
then
    echo "Please run this script with \"bash\""
    exit 1
fi

if [[ "$EUID" -ne 0 ]]
    then
    echo "Sorry, you need to run this as root"
    exit 1
fi

# check os version

if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    ...
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    ...
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
fi

echo "Running on (${OS} ${VER})"

printf "Which function?\n1: 新建網頁\n2: 網頁版本更新\n3. Clean up.\n4. Let's encrypt 更新\n"
read -e -p "Select: " -i "1" function

if [ ${function} == "1" ]
then
    read -e -p "Domain name without subdomain: " -i "example.com" domain
    read -e -p "Subdomain of this server(i.e. blog): " -i "www" subdomain
    read -e -p "Add blank subdomain support? (Y/n): " -i "Y" blanksupport
    read -e -p "Username you want to create: " -i "" username
    read -e -p "User group: " -i "webapps" usergroup
    read -e -p "New project name (空白則繼續設定git path): " -i "" projectname

    if [ ${projectname} == "" ]
    then
        # git information
        read -e -p "From github link: " -i "https://github.com/***/***.git" gitlink
        read -e -p "要抓的branch名稱：" -i "master" branchname
        gitname=$(echo $gitlink | rev | cut -d"/" -f 1 | rev)
        gitfoldername=$(echo $gitname | cut -d"." -f 1)
    fi

    echo "Creating user \"${username}\" in \"${usergroup}\""
    uid=$(id -u ${username} 2> /dev/null)

    if [ -z ${uid} ]
    then
        ## user not created
        echo "Username available"
    else
        # echo "User exists"
        user_exist=1
    fi

    groupcount=$(grep -c ${usergroup}: /etc/group)
    if [ ${groupcount} == 0 ]
    then
        echo "No such usergroup"
    else
        # echo "Usergroup exists"
        group_exist=1
    fi

    sure=0
    if [ ${user_exist} == 1 ] && [ ${group_exist} == 0 ]
    then
        echo "Username not available!"
        exit 1
    elif [ ${user_exist} == 1 ] && [ ${group_exist} == 1 ]
    then
        read -e -p "Sure to use exist user \"${username}:${usergroup}\" to create? (Y/n) " -i "Y" sure
        if [ ${sure} == 'y' ] || [ ${sure} == 'Y' ]
        then
            sure=2
        else
            sure=0
            echo "End progress"
            exit 1
        fi
    elif [ ${user_exist} == 0 ] && [ ${group_exist} == 1 ]
    then
        read -e -p "Create \"${username}\" under exist group \"${usergroup}\"? (Y/n) " -i "Y" sure
        if [ ${sure} == 'y' ] || [ ${sure} == 'Y' ]
        then
            sure=1
        else
            sure=0
            echo "End progress"
            exit 1
        fi
    else
        # all is well
        groupadd --system ${usergroup}
        sure=1
    fi

    if [ ${sure} > 0 ]
    then
        if [ ${sure} == 1 ]
        then
            # create dir and user
            mkdir /home/${username}
            useradd --system --gid ${usergroup} --shell /bin/bash --home /home/${username} ${username}
            chown -R ${username}:${usergroup} /home/${username}
            echo "[Info] 使用者 ${username}:${usergroup} 已建立"
        fi

        # semi-global var here
        HOMEDIR=$(sudo -u ${username} -i eval 'echo $HOME')
        echo ${username}:${usergroup} home dir at ${HOMEDIR}
        PROJECT_HOME=${HOMEDIR}/${domain}/_${subdomain}
        
        # setup require software
        echo "Building environment..."

        apt-get update
        apt-get -y install python3
        apt-get -y install python3-pip
        apt-get -y install python3-venv
        apt-get -y install nginx
        apt-get -y install supervisor
        
        echo "Environment created successfully!"

        # create project folder

        while [ ! -f ${PROJECT_HOME}/site/${projectname}/settings.py ]
        do
            echo "[Info] 建立檔案結構"
            mkdir ${HOMEDIR}/${domain}
            cd ${HOMEDIR}/${domain}
            mkdir ${subdomain}venv
            mkdir _${subdomain}

            cd ${PROJECT_HOME}
            mkdir bin
            mkdir log
            mkdir run
            mkdir site
            touch bin/gunicorn_start.bash
            touch ${PROJECT_HOME}/log/gunicorn_supervisor.log

            [ ! -f ${HOMEDIR}/${domain}/${subdomain}venv/bin/activate ] && echo "[Info] Virtual environment 建立中" && python3 -m venv ${HOMEDIR}/${domain}/${subdomain}venv
            echo "Venv check done."

            echo "Activating venv..."
            source ${HOMEDIR}/${domain}/${subdomain}venv/bin/activate

            # =============== venv ON ==============
            echo "Pip installing mods..."
            if [ $(grep -i -c "django" <<< $(pip freeze 2> /dev/null)) == 0 ]
            then 
                echo "Installing django..."
                pip install django &> /dev/null
            fi

            if [ $(grep -i -c "gunicorn" <<< $(pip freeze 2> /dev/null)) == 0 ]
            then
                echo "Installing gunicorn..."
                pip install gunicorn &> /dev/null
            fi

            echo "Creating project..."
            if [ -f ${PROJECT_HOME}/site/manage.py ]
            then
                echo "Project exists! Please use another project name."
                exit 1
            else
                python ${HOMEDIR}/${domain}/${subdomain}venv/bin/django-admin.py startproject ${projectname} ${PROJECT_HOME}/site
            fi
            sleep 0.5s
            mkdir ${PROJECT_HOME}/site/public_statics
            mkdir ${PROJECT_HOME}/site/collected_statics
            mkdir ${PROJECT_HOME}/site/templates
            deactivate
            # =============== venv OFF ==============

            chown -R ${username}:${usergroup} /home/${username}
        done

        cd ${PROJECT_HOME}/site
        # edit allow host to *
        line_count=$(echo $(grep -n 'ALLOWED_HOSTS' ${PROJECT_HOME}/site/${projectname}/settings.py) | cut -d":" -f 1)
        sed "${line_count}cALLOWED_HOSTS = ['*']" -i ${PROJECT_HOME}/site/${projectname}/settings.py

        # add static file path
        line_count=$(echo $(grep -n 'STATIC_URL = ' ${PROJECT_HOME}/site/${projectname}/settings.py) | cut -d":" -f 1)
        sed "${line_count} a\nSTATICFILES_DIRS = [\n    os.path.join(BASE_DIR, \"public_statics\"),\n]\n\nSTATIC_ROOT = './collected_statics/'\n" -i ${PROJECT_HOME}/site/${projectname}/settings.py

        echo "settings.py file edited."
        # gunicorn ${projectname}.wsgi:application --bind 0.0.0.0:9527

        cd ${PROJECT_HOME}/bin

        echo "#!/bin/bash" >> gunicorn_start.bash
        echo "NAME=\"${subdomain}_$(echo ${domain} | sed 's/\./_/g')\"" >> gunicorn_start.bash
        echo "DJANGODIR=${PROJECT_HOME}/site" >> gunicorn_start.bash
        echo "SOCKFILE=${PROJECT_HOME}/run/gunicorn.sock" >> gunicorn_start.bash
        echo "USER=${username}" >> gunicorn_start.bash
        echo "GROUP=${usergroup}" >> gunicorn_start.bash
        echo "NUM_WORKERS=3" >> gunicorn_start.bash
        echo "DJANGO_SETTINGS_MODULE=${projectname}.settings" >> gunicorn_start.bash
        echo "DJANGO_WSGI_MODULE=${projectname}.wsgi" >> gunicorn_start.bash
        echo "LOGFILE=${PROJECT_HOME}/log/gunicorn_exec.log" >> gunicorn_start.bash
        echo "echo \"Starting \$NAME as \`whoami\`\"" >> gunicorn_start.bash
        ###
        echo "cd \$DJANGODIR" >> gunicorn_start.bash
        echo "source ../../${subdomain}venv/bin/activate" >> gunicorn_start.bash
        echo "export DJANGO_SETTINGS_MODULE=\$DJANGO_SETTINGS_MODULE" >> gunicorn_start.bash
        echo "export PYTHONPATH=\$DJANGODIR:\$PYTHONPATH" >> gunicorn_start.bash
        ###
        echo "RUNDIR=\$(dirname \$SOCKFILE)" >> gunicorn_start.bash
        echo "test -d \$RUNDIR || mkdir -p \$RUNDIR" >> gunicorn_start.bash
        ###
        echo "exec gunicorn \${DJANGO_WSGI_MODULE}:application --name \$NAME --workers \$NUM_WORKERS --user=\$USER --group=\$GROUP --bind=unix:\$SOCKFILE --log-level=debug --log-file=\$LOGFILE" >> gunicorn_start.bash

        chmod u+x gunicorn_start.bash
        chown ${username}:${usergroup} gunicorn_start.bash

        # supervisord
        p_name=${subdomain}_$(echo ${domain} | sed 's/\./_/g')
        echo "[program:${p_name}]" >> /etc/supervisor/conf.d/${p_name}.conf
        echo "command = ${PROJECT_HOME}/bin/gunicorn_start.bash" >> /etc/supervisor/conf.d/${p_name}.conf
        echo "user = ${username}" >> /etc/supervisor/conf.d/${p_name}.conf
        echo "stdout_logfile = ${PROJECT_HOME}/log/gunicorn_supervisor.log" >> /etc/supervisor/conf.d/${p_name}.conf
        echo "redirect_stderr = true" >> /etc/supervisor/conf.d/${p_name}.conf
        echo "environment=LANG=en_US.UTF-8,LC_ALL=en_US.UTF-8" >> /etc/supervisor/conf.d/${p_name}.conf

        supervisorctl reread
        sleep 0.1s
        supervisorctl update
        sleep 1s
        supervisorctl status ${p_name}

        #nginx
        echo "upstream ${p_name} {" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    server unix:${PROJECT_HOME}/run/gunicorn.sock fail_timeout=0;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "}" >> /etc/nginx/sites-available/${p_name}.conf
        echo "server {" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    listen 80;" >> /etc/nginx/sites-available/${p_name}.conf
        if [ ${blanksupport} == "Y" ]
        then
            echo "    server_name ${subdomain}.${domain} ${domain};" >> /etc/nginx/sites-available/${p_name}.conf
        else
            echo "    server_name ${subdomain}.${domain};" >> /etc/nginx/sites-available/${p_name}.conf
        fi
        echo "    client_max_body_size 4G;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    access_log ${PROJECT_HOME}/log/nginx-access.log; " >> /etc/nginx/sites-available/${p_name}.conf
        echo "    error_log ${PROJECT_HOME}/log/nginx-error.log;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    location /static/ {" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        alias ${PROJECT_HOME}/site/collected-statics/;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    }" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    location / {" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        proxy_set_header Host \$http_host;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        proxy_redirect off;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        if (!-f \$request_filename) {" >> /etc/nginx/sites-available/${p_name}.conf
        echo "            proxy_pass http://${p_name};" >> /etc/nginx/sites-available/${p_name}.conf
        echo "            break;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        }" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    }" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    error_page 500 502 503 504 /500.html;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    location = /500.html {" >> /etc/nginx/sites-available/${p_name}.conf
        echo "        root ${PROJECT_HOME}/site/templates/;" >> /etc/nginx/sites-available/${p_name}.conf
        echo "    }" >> /etc/nginx/sites-available/${p_name}.conf
        echo "}" >> /etc/nginx/sites-available/${p_name}.conf

        ln -s /etc/nginx/sites-available/${p_name}.conf /etc/nginx/sites-enabled/${p_name}.conf
        service nginx restart
        
        echo "Server deploy script finished successfully."
        echo "You can visit ${subdomain}.${domain} to see the result."
    fi
elif [ ${function} == "2" ]; then

    # just for notice
    read -e -p "檔案有放在子網域的資料夾(e.g. _www)裡面嗎？" -i "Y" xxx
    read -e -p "建議手動備份db.sqlite3一下！" -i "Y" xxx

    # git information
    read -e -p "Github clone 的 link: " -i "https://github.com/***/***.git" gitlink
    read -e -p "要抓的branch名稱：" -i "master" branchname
    gitname=$(echo $gitlink | rev | cut -d"/" -f 1 | rev)
    gitfoldername=$(echo $gitname | cut -d"." -f 1)

    # others
    read -e -p "username:group？" -i "cougarbot:webapps" namegroup
    read -e -p "用自己的db？ (放在當前資料夾的*.sqlite3) (N if no)：" -i "N" mydb

    # START
    echo "關閉nginx服務，網站下線"
    sudo service nginx stop

    fname=`date "+%Y-%m-%d-%H-%M-%S-db.sqlite3"`
    echo "備份資料庫中，檔名為$fname..."
    cp ./site/db.sqlite3 ./$fname
    echo "git clone最新檔案"
    sudo git clone --single-branch --branch $branchname $gitlink

    echo "移除舊的的site資料夾..."
    sudo rm -rf ./site
    mv ./$gitfoldername ./site
    if [ "$mydb" != "N" ]
    then
        echo "Copy self prepare DB back."
        cp ./$mydb ./site/db.sqlite3
    else
        echo "Copy backup DB back."
        cp ./$fname ./site/db.sqlite3
    fi

    cd site
    echo "Collecting static files..."
    ../../venv/bin/python3 manage.py collectstatic
    echo "重置db, migration"
    ../../venv/bin/python3 manage.py migrate
    cd ../

    sudo chown -R $namegroup ./site

    sudo service nginx start
    sudo service supervisor start
    sudo supervisorctl reload

elif [ ${function} == "3" ] 
then
    echo "----- 清理模式 -----"
    read -e -p "Domain: " -i "" domain
    read -e -p "Subdoman: " -i "www" subdomain
    read -e -p "Username: " -i "" username
    read -e -p "Delete user? (N/y):  " -i "Y" deluser
    read -e -p "Delete group? (N/y):  " -i "N" delgroup

    service nginx stop
    sleep 0.5s

    fileprefix=$(echo ${subdomain}.${domain} | sed 's/\./_/g')
    echo "Cleaning up for ${fileprefix}"
    rm -rf /home/${username}/${domain}/_${subdomain}/
    rm -rf /etc/supervisor/conf.d/${fileprefix}.conf
    rm -rf /etc/nginx/sites-available/${fileprefix}.conf
    rm -rf /etc/nginx/sites-enabled/${fileprefix}.conf

    supervisorctl reread
    sleep 0.5s
    supervisorctl update
    sleep 1s

    echo "[Info] 檢查 supervisor config 是否還存在"
    supervisorctl status ${fileprefix}
    echo "[Info] 重啟nginx"
    service nginx restart
    echo "[Info] 停止nginx"
    service nginx stop

    if [ ${deluser} == 'Y' ]
    then
        echo "[Info] 刪除使用者${username}"
        userdel -rf ${username}
    fi
    if [ ${delgroup} == 'Y' ]
    then
        read -e -p "Group you want to DELETE: " -i "webapps" usergroup
        groupdel ${usergroup}
    fi

    read -p "--- Press any key to continue ---"
else
    echo "Wrong option, bye!"
fi

