# Stock image plus an ssh client, so this container can log in to target.
FROM openbao/openbao:2.7.1
USER root
RUN apk add --no-cache openssh-client
USER openbao
