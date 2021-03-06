ALTER TABLE seq_request MODIFY seq_type ENUM('Single ended sequencing','Paired end sequencing','HiSeq Paired end sequencing','MiSeq sequencing','Single ended hi seq sequencing')  NOT NULL; 
DROP VIEW if EXISTS `latest_seq_request`;
create view latest_seq_request as select * from seq_request where latest=true;
update schema_version set schema_version=17;
