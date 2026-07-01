FROM mysql:8.0

ENV MYSQL_ROOT_PASSWORD=root
ENV MYSQL_DATABASE=sistema_estoque

COPY init.sql /docker-entrypoint-initdb.d/init.sql

EXPOSE 3306
