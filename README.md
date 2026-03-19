# Search report service

# How to run
```
chmod +x run.sh
./run.sh GH_ACCOUNT GH_ACCESS_TOKEN

#Monitor
docker logs -f search-report-service
```

# Logging
For more logging options use following variables 
```
    root: ${ROOT_LOGGING_LEVEL:WARN}
    org.epo.itc: ${APP_LOGGING_LEVEL:INFO}
    org.springframework: ${SPRING_LOGGING_LEVEL:WARN}
    org.hibernate.SQL: ${SQL_LOGGING_LEVEL:WARN}
```
