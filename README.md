# How to run 

docker run -d \
  --name search-report-service \
  -p 8080:8080 \
  -v /tmp/search-report-db:/data/db \
  -e DB_PATH=/data/db \
  -e SPRING_PROFILES_ACTIVE=prod \
  -e IDENTITY_PROVIDER=azure \
  -e OPENID_CLIENT_ID="AZURE_CLIENT_ID" \
  -e OPENID_CLIENT_SECRET="AZURE_CLIENT_SECRET" \
  -e OPENID_REDIRECT_URI="https://YOUR_DOMAIN/search-report-service/" \
  -e OPENID_SEARCH_SCOPE="api://b16225bd-49b8-4999-b571-c19a911ae1ec/search" \
  -e SEARCH_REPORT_SERVICE_CONTEXT_PATH=/search-report-service \
  -e SEARCH_REPORT_SERVICE_PORT="8080" \
  search-report-service
