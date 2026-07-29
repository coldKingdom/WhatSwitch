import { looksLikeSecretParam as f } from '../src/lib/installerDetect';
const should = ['LICENSEKEY','LICENCEKEY','SERIALNUMBER','PASSWORD','ADMINPASSWORD','PIDKEY','PRODUCTKEY','APIKEY','API_KEY','AUTHTOKEN','ACTIVATIONCODE','REGCODE','CDKEY','SVCPASSWORD','PASSPHRASE','DBPWD','CLIENTSECRET'];
const shouldNot = ['LICENSEACCEPTED','ACCEPTEULA','LICENSEAGREEMENT','TOKENPATH','AUTHSERVER','INSTALLDIR','ALLUSERS','TARGETDIR','SERIALPORTMODE','SHOWPASSWORD','APIURL','VALIDATETOKEN'];
let bad = 0;
for (const n of should) if (!f(n)) { console.log('MISS  ' + n); bad++; }
for (const n of shouldNot) if (f(n)) { console.log('FALSE ' + n); bad++; }
console.log(bad === 0 ? 'all ' + (should.length + shouldNot.length) + ' cases ok' : bad + ' wrong');
