FROM ubuntu:15.04

RUN apt-get update && apt-get install -y build-essential curl git ruby bundler

RUN git clone --depth 1 https://github.com/CleverRaven/Cataclysm-DDA.git /opt/cdda

ADD ./Gemfile.lock /opt/rjb/Gemfile.lock
ADD ./Gemfile /opt/rjb/Gemfile

RUN cd /opt/rjb && bundle install

ADD ./ /opt/rjb

WORKDIR /opt/rjb

ENTRYPOINT ["/opt/rjb/startup.sh"]

