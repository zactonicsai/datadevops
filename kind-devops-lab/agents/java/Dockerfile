# Jenkins build agent for Java projects.
# Base image already knows how to connect back to the Jenkins controller.
FROM jenkins/inbound-agent:latest-jdk21

USER root

ARG MAVEN_VERSION=3.9.9
ARG GRADLE_VERSION=8.14

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Maven
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      | tar xz -C /opt \
 && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn

# Gradle
RUN curl -fsSL -o /tmp/gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && unzip -q /tmp/gradle.zip -d /opt && rm /tmp/gradle.zip \
 && ln -s "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle

USER jenkins
ENV MAVEN_OPTS="-Dmaven.repo.local=/home/jenkins/.m2/repository"
