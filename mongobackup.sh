#!/bin/bash
# Снять коммент для включения отладки
# set -x
# Скрипт резервного копирования базы MongoDB
echo "************************************"
echo "** MongoDB Database Backup Script **"
echo "************************************"
# Настройки экспорта:
# путь к mongodump
DUMPCMD="/usr/bin/mongodump"
# Путь к cURL
CURL_CMD="$(which curl)"
# путь резервного копирования
EXPORT_PREFIX="/tmp/dump/daily"
# Дополнтнльный каталог по пути экспорта
EXPORT_SUBDIR=""
# Количество бэкапов в стеке. При "0" ротация выключена
BACKUPS_CNT="0"
# Получаем текущую дату в переменную
TODAY="$(date +%d.%m.%Y)"
# Формат даты в регекспе
DATE_REGEXP="[0-9]\{2\}.[0-9]\{2\}.[0-9]\{4\}"

# Настройки для FTP:
# нужно ли бэкап заливать на FTP
FTPBACKUP="false"
# хост
FTPHOST="127.0.0.1"
# логин
FTPUSER="user"
# пароль
FTPPASS="pass"
# директория на хосте, в данном случае имя машины, на которой запускаем бэкап
FTPDIR="$(hostname)"

# Функция подсчета количества файлов по заданной маске
# На вход принимает 2 параметра, в контексте функции
# они приходят в переменные $1, $2
function countFilesByMask() {
  if [ ! -d "$1" ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo "[WARN][countFilesByMask]: wrong or empty parameter passed! Please check your configuration!"
    exit -1
  else
    return $(find "$1" -maxdepth 1 -type f -printf "%f\n" | grep -c "$2")
  fi
}

# Функция ищет и удаляет самый старый файл в каталоге экспорта
# Используется дата в имени файла. На вход принимает 3 параметра
# в случае ошибки возвращает 0, при положительном результате 1
function delOlderFile() {
  # Маленький грязный хак - получаем текущее время в виде Unix timestamp
  # Надо ведь с чем-то сравнивать даты в файлах
  unixtime=$(date "+%s")
  # Резервируем переменную для результата
  olderfile=""
  # Ищем файлы бэкапов
  local lines=$(find "$1" -maxdepth 1 -type f -printf "%f\n" | grep "$2")
  for line in $lines; do
    # Дата у нас в привычном русском формате,
    # а сравнивать будем секунды, прошедшие с начала эпохи юникс
    # Разбиваем текущую строку на элементы
    filedate=$(echo $line | grep -o "$3")
    # Не красиво, но надо дату из формата dd.mm.yyyy перегнать в mm/dd/yyyy
    # чтобы отдать на вход date -d, для этого разбиваем строку в массив,
    # заменяя "." на "\n". Переменная - local, чтобы нигде никому не мешала
    local dp=($(echo $filedate | tr "." "\n"))
    local filetime=$(date -d ${dp[1]}/${dp[0]}/${dp[2]} "+%s")
    # Получаем имя файла для самого старого бэкапа
    if [ $filetime -le $unixtime ]; then
      unixtime=$filetime
      olderfile=$line
    fi
  done
  # Получили имя самого старого файла. Можно удалять.
  rm $1"/"$olderfile
}

# Функция создания пути экспорта, если он не сушествует
# В качестве параметра принимает путь,
# возвращает 1 при удачном завершении
function createLocalBackupDir() {
  # Если параметр пустой - ничего не делаем
  if [ -n "$1" ]; then
    # Проверяем - существует ли директория
    # При необходимости - создаем
    if [ ! -d "$1" ]; then
      # Типа аналог try-catch - весь вывод в /dev/null и ловим код ошибки
      mkdir -p "$1" 2>/dev/null
      if (($? == 0)); then
        return 0
      else
        return 1
      fi
    else
      return 0
    fi
  else
    return 1
  fi
}

function createRemoteBackupDir() {
  FTPCMD="${CURL_CMD} --user ${FTPUSER}:${FTPPASS} ftp://${FTPHOST}/${FTPDIR}/"
  eval "${FTPCMD} --head 2>/dev/null"
  # Directory not exists
  if [ $? -ne 0 ]; then
    # Create directory
    eval "${FTPCMD} --ftp-create-dirs 2>/dev/null"
    if [ $? -ne  0 ]; then
      return 1
    fi
  fi
  return 0
}

# $1 - local file full path
# $2 - remote file name
function processFTPBackup() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    exit 1
  fi
  # Заливаем на FTP
  if [ -f "$1" ] && [ "$FTPBACKUP" = "true" ]; then
    createRemoteBackupDir
    if (($? == 0)); then
      uploadViaCURL "$1" "$2"
    else
      exit 1
    fi
  fi
}

# Заливаем файл на FTP. Функция принимает 2 параметра, т.к. некоторые FTP-сервера
# (например vsftpd) не умеют вычленять имя по последнему слэшу
# $1 - полный путь к локальному файлу
# $2 - имя файла на удаленном сервере
function uploadFTP() {
  # -n option disables auto-logon
  # -i option disables prompts for multiple transfers
  ftp -ni $FTPHOST <<EOF
user $FTPUSER $FTPPASS
binary
passive
cd $FTPDIR
put $1 $2
bye
EOF
}

# $1 - полный путь к локальному файлу
# $2 - имя файла на удаленном сервере
function uploadViaCURL() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    exit 1
  fi
  FTPCMD="${CURL_CMD} ftp://${FTPHOST}/${FTPDIR}/$2"
  eval "${FTPCMD} -T $1 --user ${FTPUSER}:${FTPPASS}"
}


# Скажем так, это своеобразный метод "для перегрузки",
# т.е. можно поменять реализацию и экспортировать хоть MySQL, хоть Oracle
function dumpDB() {
  # Формируем комманду для запуска экспорта
  DUMPCMD="$DUMPCMD -d$DBNAME"

  # Логин
  if [ -n "$DBUSER" ]; then
    DUMPCMD="$DUMPCMD --u$DBUSER"
  fi

  # Пароль
  if [ -n "$DBPASS" ]; then
    DUMPCMD="$DUMPCMD -p$DBPASS"
  fi

  # Если задано архиварование GZip
  if [ "$DBZIP" = "true" ]; then
    TARCMD="-czf"
    FEXT=".tar.gz"
  else
    TARCMD="-cf"
    FEXT=".tar"
  fi

  # Формируем имя по принципу хост_база
  BACKUP_NAME="$(hostname)_${DBNAME}_"

  # Ротация бэкапов
  if [ $BACKUPS_CNT -gt 0 ]; then
    # Функции в bash - не совсем функции.
    # Комманда return возвращает не результат выполнения, а "код ошибки"
    # Поэтому, чтобы получить искомое число перехватываем STDERROR
    countFilesByMask "${EXPORT_PREFIX}" "^${BACKUP_NAME}${DATE_REGEXP}${FEXT}$"
    funcres="$?"

    # Проверяем, не вышли ли мы за размер стэка бэкапов
    if [ $funcres -ge $BACKUPS_CNT ]; then
      delOlderFile $EXPORT_PREFIX "^"$BACKUP_NAME$DATE_REGEXP$FEXT"$" $DATE_REGEXP
    fi
  fi

  # Монго экспортирует базу в директорию, т.к. дамп содержит несколько файлов
  OUTPUT="${EXPORT_PREFIX}/${BACKUP_NAME}${TODAY}"

  # Делаем дамп базы данных.
  eval "${DUMPCMD} --out ${OUTPUT}"

  # Архивируем и удаляем директорию
  if [ -d "$OUTPUT" ] && [ -n "$(ls $OUTPUT)" ]; then
    # Чтобы tar не строил в архиве полное дерево каталогов
    eval "tar $TARCMD $OUTPUT$FEXT -C $EXPORT_PREFIX $BACKUP_NAME$TODAY  && rm -rf $OUTPUT"
    processFTPBackup "${OUTPUT}${FEXT}" "${BACKUP_NAME}${TODAY}${FEXT}"
  fi
}

function printUsage() {
  echo "Right usage syntax: $0 -d dbname"
  echo "  -u username"
  echo "  -p password"
  echo "  [--prefix to override default local backup directory]"
  echo "  [--subdir to perform backup saving within [location]/[subdir] path]"
  echo "  [-z to create tarball with gzip compression]"
  echo "  [-r or --rotate to enable rotation with default stack size of 20 files]"
  echo "  [-n for custom backup stack size]"
  echo "  [-f to enable FTP uploading]"
  echo "  [--ftp-host to override FTP hostname]"
  echo "  [--ftp-user to override FTP login]"
  echo "  [--ftp-pass to override FTP password]"
  echo "  [--ftp-prefix to override default FTP backup directory]"
}

# Обрабатываем входные параметры скрипта
args=("$@")
for index in ${!args[*]}; do
  param="${args[$index]}"
  case "$param" in
  "-u")
    DBUSER="${args[$index + 1]}"
    ;;
  "-p")
    DBPASS="${args[$index + 1]}"
    ;;
  "-d")
    DBNAME="${args[$index + 1]}"
    ;;
  "-z")
    DBZIP="true"
    ;;
  "-f")
    FTPBACKUP="true"
    ;;
  "--ftp-user")
    FTPUSER="${args[$index + 1]}"
    ;;
  "--ftp-pass")
    FTPPASS="${args[$index + 1]}"
    ;;
  "--ftp-host")
    FTPHOST="${args[$index + 1]}"
    ;;
  "--ftp-prefix")
    FTPDIR="${args[$index + 1]}"
    ;;
  "--rotate" | "-r")
    BACKUPS_CNT="20"
    ;;
  "--prefix")
    EXPORT_PREFIX="${args[$index + 1]}"
    ;;
  "--subdir")
    EXPORT_SUBDIR="${args[$index + 1]}"
    ;;
  "-n")
    BACKUPS_CNT="${args[$index + 1]}"
    ;;
  "-h")
    printUsage
    exit 0
    ;;
  esac
done

# Проверяем правильность введенных данных
# если не указана БД ( можно дополнить проверкой и на имя пользователя)
# выдаем предупреждение и завершаем работу
if [ -z "${DBNAME}" ]; then
  echo "[WARN]: Empty parameter!"
  echo "- Database name expected!"
  printUsage
  exit 1
fi

TMP_EXPORT_PATH=""
# Создаем иерархию каталогов экспорта (если нужно)
if [ -n "$EXPORT_SUBDIR" ]; then
  TMP_EXPORT_PATH="${EXPORT_PREFIX}/${EXPORT_SUBDIR}"
else
  TMP_EXPORT_PATH="${EXPORT_PREFIX}"
fi

createLocalBackupDir "${TMP_EXPORT_PATH}"
if (($? == 0)); then
  EXPORT_PREFIX="${TMP_EXPORT_PATH}"
else
  echo "Destination directory '${TMP_EXPORT_PATH}' was not created!"
fi

# Запускаем бэкап
dumpDB
