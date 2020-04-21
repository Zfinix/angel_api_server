import 'package:angel_framework/angel_framework.dart';
import 'package:angel_container/mirrors.dart';
import 'package:angel_mongo/angel_mongo.dart';
import 'package:mongo_dart/mongo_dart.dart';

class User extends Model {
  String username;
  String password;
}

void main() async {
  
  var app = Angel(reflector: MirrorsReflector());
  var db = Db('mongodb://localhost:27017/game-of-thrones');
  await db.open();
  

  if(db.state == State.OPEN){
    print('Connected to database');
  }

  var collection = db.collection('characters');
  
  print(await collection.find(where.sortBy('name')).toList());
  var service = app.use('/api/users', MongoService(collection));

  service.afterCreated.listen((event) {
    print('New user: ${event.result}');
  });
}
