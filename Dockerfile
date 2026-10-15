# Virtual Boca ticket printer: FGL on TCP 9100 -> numbered PDFs in /tickets.
#   docker build -t fgl-printer .
#   docker run --rm -p 9100:9100 -v "$PWD/tickets:/tickets" fgl-printer
FROM ruby:3.2-slim

WORKDIR /app

# All runtime dependencies are pure Ruby, so no compiler toolchain is needed.
COPY fgl_pdf.gemspec Gemfile README.md LICENSE ./
COPY lib ./lib
COPY exe ./exe
COPY fonts ./fonts

RUN gem build fgl_pdf.gemspec \
 && gem install --no-document ./fgl_pdf-*.gem \
 && rm -f ./fgl_pdf-*.gem

ENV FGL_PDF_OUT=/tickets \
    FGL_PDF_PORT=9100
VOLUME /tickets
EXPOSE 9100

CMD ["fgl-printer", "--out", "/tickets"]
