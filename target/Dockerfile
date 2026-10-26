# HashiCorp's download site is geo-blocked, so build the helper from source.
FROM golang:1.27 AS helper
RUN CGO_ENABLED=0 go install github.com/hashicorp/vault-ssh-helper@v0.2.4

FROM ubuntu:26.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd
COPY --from=helper /go/bin/vault-ssh-helper /usr/local/bin/vault-ssh-helper
COPY config.hcl /etc/vault-ssh-helper.d/config.hcl
COPY pam-sshd /etc/pam.d/sshd
COPY otp.conf /etc/ssh/sshd_config.d/otp.conf
# '*' unlocks the account without giving it a usable password.
RUN useradd -m -s /bin/bash user && usermod -p '*' user
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
