FROM eclipse-temurin:8-jre

RUN apt-get update && apt-get install -y wget && rm -rf /var/lib/apt/lists/*

RUN wget https://archive.apache.org/dist/tomcat/tomcat-8/v8.5.100/bin/apache-tomcat-8.5.100.tar.gz -O /tmp/tomcat.tar.gz && \
    tar xzf /tmp/tomcat.tar.gz -C /opt && \
    mv /opt/apache-tomcat-8.5.100 /opt/tomcat && \
    rm /tmp/tomcat.tar.gz && \
    rm -rf /opt/tomcat/webapps/*

ENV CATALINA_HOME=/opt/tomcat
ENV PATH=$CATALINA_HOME/bin:$PATH

COPY SistemaEstoque/ /opt/tomcat/webapps/SistemaEstoque/

EXPOSE 8080

CMD ["catalina.sh", "run"]
