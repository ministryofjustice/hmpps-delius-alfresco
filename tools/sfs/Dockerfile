FROM quay.io/alfresco/alfresco-shared-file-store:2.1.2

COPY ./alfresco-shared-file-store-2.1.2.jar /usr/bin/alfresco-shared-file-store.jar

ENTRYPOINT ["/bin/sh", "-c", "java $JAVA_OPTS -jar /usr/bin/alfresco-shared-file-store.jar"]
