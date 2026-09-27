# 検証専用: WildFly (JBoss EAP のアップストリーム) を EAP と同じ /opt/jboss-eap に配置した「疑似 EAP」
ARG WILDFLY_IMAGE=quay.io/wildfly/wildfly:26.1.3.Final-jdk11
FROM ${WILDFLY_IMAGE}
USER root
RUN cp -a /opt/jboss/wildfly /opt/jboss-eap
# 任意のタイミングで server.log に 1 行出すための検証用アプリ (log.jsp?who=XXX)
COPY ticker.war /opt/jboss-eap/standalone/deployments/ticker.war
