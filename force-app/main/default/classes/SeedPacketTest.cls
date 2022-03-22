@isTest
public with sharing class SeedPacketTest {
    
    static testMethod void testSeedPacketCreate() {
        
        TriggerOnOff__c tAcct = new TriggerOnOff__c(Name = 'Account', Active__c = false);
        TriggerOnOff__c tContact = new TriggerOnOff__c(Name = 'Contact', Active__c = false);
        insert tAcct;
        insert tContact;

        Account a = new Account(name = 'test');
        insert a;
        List<Contact> contactList = new List<Contact>();
        for(integer i=0; i<20; i++){
            contactList.add(new Contact(firstName = String.valueOf(i), 
                                lastname = String.valueOf(i+1), 
                                email=String.valueOf(i)+'@testing.com', 
                                phone = '(10)049349324'+String.valueOf(i), 
                                birthdate = Date.today().adddays(i - 1000)));
        }
        insert contactList;
        List<Task> tList = new List<Task>();
        for(integer i=0; i<20; i++){
            tList.add(new Task( WhoId = contactList[0].Id,
                                Subject = 'testing',
                                Priority = 'Standard',
                                Description = 'testing',
                                ActivityDate = Date.today()));
        }
        insert tList;
        
        // assumes seedling test Static Resource is available
        SeedPacket.Packet p = 
            SeedPacket.createPacketPayload('test_seedpacket_definition',null); // should run without error. Will throw runtime if does.
        
        // all contacts should now be different 
        for(integer j=0; j<p.ingredients[0].records.size(); j++){
            for(string fld : new List<string>{'FirstName','LastName','Phone','Email'}){
                System.assertNotEquals(p.ingredients[0].records[j].get(fld), contactList[j].get(fld), fld+'should be different');
            }
        }
        SeedPacket.createPacket('test_seedpacket_definition'); // just cover the public method. Will have crapped out by now if at all!
    }

    static testMethod void testSeedPacketPlant(){

        TriggerOnOff__c tAcct = new TriggerOnOff__c(Name = 'Account', Active__c = false);
        TriggerOnOff__c tContact = new TriggerOnOff__c(Name = 'Contact', Active__c = false);
        insert tAcct;
        insert tContact;
        Test.startTest();
        SeedPacket.plantSeedPacket('test_seedpacket_result');
        system.assertNotEquals(0,
                        [select count() from Contact where email like '%@newemail.com'],
                        'Should have generated the seed data');
        
        
        SeedPacket.resetData('test_seedpacket_result');
        Test.stopTest();
    }

    static testMethod void testStepsAutogenerate(){
        
        TriggerOnOff__c tAcct = new TriggerOnOff__c(Name = 'Account', Active__c = false);
        TriggerOnOff__c tContact = new TriggerOnOff__c(Name = 'Contact', Active__c = false);
        insert tAcct;
        insert tContact;

        Account a = new Account(name = 'test');
        insert a;
        List<Contact> contactList = new List<Contact>();
        for(integer i=0; i<20; i++){
            contactList.add(new Contact(firstName = String.valueOf(i), 
                                lastname = String.valueOf(i+1), 
                                email=String.valueOf(i)+'@testing.com', 
                                phone = '(10)049349324'+String.valueOf(i), 
                                birthdate = Date.today().adddays(i - 1000)));
        }
        insert contactList;
       

        Test.startTest();
            List<SeedPacket.Step> steps = SeedPacket.generateSeedPacketSteps('Select id from Account');
            System.assert(!steps.isEmpty(),'Should have generated some steps from available dataset');
            
        Test.stopTest();
        
    }
}
