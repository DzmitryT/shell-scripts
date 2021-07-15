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
DATE_REGEXP='[0-9]{2}.[0-9]{2}.[0-9]{4}'
# Скрипт на AWK для переформатирования даты
# предполагает наличие в имнеи файла даты и времени (дд.мм.гггг-ЧЧ24.Мин)
AWK_CMD='{ if (index($0,"-") > 0) {
             split($0,parts,"-");
             dpart=parts[1];
             tpart=parts[2];
          } else {
             dpart=$0;
             tpart="";
          }
             split(dpart,dparts,".");
             printf("%02d/%02d/%02d %s\n",dparts[2],dparts[1],dparts[3],gensub(/\./,":","g",tpart));
        }'

# Настройки для FTP:
# нужно ли бэкап заливать на FTP
FTP_ENABLED="false"
# хост
FTP_HOST="127.0.0.1"
# логин
FTP_USER="user"
# пароль
FTP_PASS="pass"
# директория на хосте, в данном случае имя машины, на которой запускаем бэкап
FTP_DIR="$(hostname)"
# Количество бэкапов в стеке. При "0" ротация выключена
FTP_BACKUPS_CNT="0"

# Префикс для всех FTP-операций, для исключения дублирования кода
# Если вдруг захочется сделать авторизацию через .netrc останется
# добавить один IF
function ftpCommandPrefix() {
  echo "${CURL_CMD} --user ${FTP_USER}:${FTP_PASS} ftp://${FTP_HOST}/${FTP_DIR}/"
}

# Получаем список файлов в каталоге на FTP-сервере
function ftpGetFilesList() {
  FTP_CMD="$(ftpCommandPrefix) --list-only --silent"
  eval "${FTP_CMD}"
}

# $1 - регулярное выражение для филтрации файлов
function ftpCountFiles() {
  ftpGetFilesList | grep -cE "$1"
}

# Заливаем файл на FTP. Функция принимает 2 параметра, т.к. некоторые FTP-сервера
# (например vsftpd) не хотят вычленять имя по последнему слэшу
# $1 - полный путь к локальному файлу
# $2 - имя файла на удаленном сервере
function ftpUploadFile() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    exit 1
  fi

  FTP_CMD="$(ftpCommandPrefix)"
  eval "${FTP_CMD}/$2  -T $1"
}

# Удаляем файл на FTP-сервере. Используется при ротации бэкапов
# $1 - имя файла на удаленном сервере
function ftpRemoveFile() {
  # Проверяем, что имя файла не пустое
  if [ -z "$1" ]; then
    return 1
  fi

  FTP_CMD="$(ftpCommandPrefix) --silent -Q '-DELE $1'"
  eval "${FTP_CMD}"
  if [ $? -ne 0 ]; then
    return 1
  fi
  return 0
}

# Преобразуем дату в имени файла из формата DATE_REGEXP
# в данном случае "дд.мм.гггг" в Unix Timestamp
function filenameToUnixTime() {
  echo "$1" | grep -oE "${DATE_REGEXP}" | awk "${AWK_CMD}" | xargs -I{} date -d "{}" +%s
}

# Функция ищет и  самый старый файл в списке на основании даты в имени файла.
# На вход принимает список файлов
function findOlderFileInList() {
  # Резервируем переменную для результата
  local OLDER_FILE_NAME=""
  # Маленький грязный хак - получаем текущее время в виде Unix timestamp
  # Надо ведь с чем-то сравнивать даты в файлах
  local TIMESTAMP=$(date "+%s")

  for LINE in $1; do
    # Дата у нас в человекопонятном формате,
    # Сравнивать будем секунды, прошедшие с начала эпохи юникс
    local FILE_TIMESTAMP=$(filenameToUnixTime "${LINE}")
    # Если файл старше предыдущего
    if [ "${FILE_TIMESTAMP}" -le "${TIMESTAMP}" ]; then
      TIMESTAMP="${FILE_TIMESTAMP}"
      OLDER_FILE_NAME="${LINE}"
    fi
  done
  # Получили имя самого старого файла. Возвращаем
  echo "${OLDER_FILE_NAME}"
}

# Ротация локальных бэкапов бэкапов
# $1 - шаблон имени файла
# $2 - расширение
function rotateRemoteBackups() {
  if [ $FTP_BACKUPS_CNT -gt 0 ]; then
    local CNT=$(ftpCountFiles "^${1}${DATE_REGEXP}${2}$")
    # Проверяем, не вышли ли мы за размер стэка бэкапов
    if [ "${CNT}" -ge "${FTP_BACKUPS_CNT}" ]; then
     local LINES=$(ftpGetFilesList);
     local OLD_FILE=$(findOlderFileInList "${LINES}")
     if [ -n "${OLD_FILE}" ]; then
       ftpRemoveFile "${OLD_FILE}";
     fi;
    fi
  fi
}

# Ротация локальных бэкапов бэкапов
# $1 - шаблон имени файла
# $2 - расширение
function rotateLocalBackups() {
  if [ $BACKUPS_CNT -gt 0 ]; then
    # Функции в bash - не совсем функции.
    # Комманда return возвращает не результат выполнения, а "код ошибки"
    # Поэтому, чтобы получить искомое число перехватываем STDERROR
    countFilesByMask "${EXPORT_PREFIX}" "^${1}${DATE_REGEXP}${2}$"
    # Проверяем, не вышли ли мы за размер стэка бэкапов
    if [ $? -ge $BACKUPS_CNT ]; then
      removeOlderLocalFile "^${1}${DATE_REGEXP}${2}$"
    fi
  fi
}

# Функция подсчета количества файлов по заданной маске
# На вход принимает 2 параметра, в контексте функции
# они приходят в переменные $1, $2
function countFilesByMask() {
  if [ ! -d "$1" ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo "[WARN][countFilesByMask]: wrong or empty parameter passed! Please check your configuration!"
    exit -1
  else
    return $(find "$1" -maxdepth 1 -type f -printf "%f\n" | grep -cE "$2")
  fi
}

# Функция ищет и удаляет самый старый файл в каталоге экспорта
# На вход принимает регулярное выражение для grep
function removeOlderLocalFile() {
  local LINES=$(find "${EXPORT_PREFIX}" -maxdepth 1 -type f -printf "%f\n" | grep -E "$1")
  local OLD_FILE=$(findOlderFileInList "${LINES}");
  # Получили имя самого старого файла. Можно удалять.
  if [ -n "${OLD_FILE}" ] && [ -f "${EXPORT_PREFIX}/${OLD_FILE}" ]; then
    rm "${EXPORT_PREFIX}/${OLD_FILE}"
  else
     echo "[WARN]: file does not exists ${EXPORT_PREFIX}/${OLD_FILE}!"
  fi;
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
  FTP_CMD="$(ftpCommandPrefix)"
  eval "${FTP_CMD} --head 2>/dev/null"
  # Directory not exists
  if [ $? -ne 0 ]; then
    # Create directory
    eval "${FTP_CMD} --ftp-create-dirs 2>/dev/null"
    if [ $? -ne 0 ]; then
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
  if [ -f "$1" ] && [ "$FTP_ENABLED" = "true" ]; then
    createRemoteBackupDir
    if (($? == 0)); then
      ftpUploadFile "$1" "$2"
    else
      exit 1
    fi
  fi
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

  # Ротация локальных бэкапов
  rotateLocalBackups "${BACKUP_NAME}" "${FEXT}"

  # Монго экспортирует базу в директорию, т.к. дамп содержит несколько файлов
  OUTPUT="${EXPORT_PREFIX}/${BACKUP_NAME}${TODAY}"

  # Делаем дамп базы данных.
  eval "${DUMPCMD} --out ${OUTPUT}"

  # Архивируем и удаляем директорию
  if [ -d "$OUTPUT" ] && [ -n "$(ls $OUTPUT)" ]; then
    # Чтобы tar не строил в архиве полное дерево каталогов
    eval "tar $TARCMD $OUTPUT$FEXT -C $EXPORT_PREFIX $BACKUP_NAME$TODAY  && rm -rf $OUTPUT"
    # Ротация удаленных локальных бэкапов
    rotateRemoteBackups "${BACKUP_NAME}" "${FEXT}"
    # Загрузка бэкапов на FTP
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
  echo "  [--ftp-rotate to enable FTP bsckup rotation with default stack size of 20 files]"
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
    FTP_ENABLED="true"
    ;;
  "--ftp-user")
    FTP_USER="${args[$index + 1]}"
    ;;
  "--ftp-pass")
    FTP_PASS="${args[$index + 1]}"
    ;;
  "--ftp-host")
    FTP_HOST="${args[$index + 1]}"
    ;;
  "--ftp-prefix")
    FTP_DIR="${args[$index + 1]}"
    ;;
  "--ftp-rotate")
      if [ $FTP_BACKUPS_CNT -eq 0 ]; then
        FTP_BACKUPS_CNT="20";
      fi;
    ;;
  "--rotate" | "-r")
      if [ $BACKUPS_CNT -eq 0 ]; then
        BACKUPS_CNT="20";
      fi;
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
